-module(local_consensus_engine).
-behaviour(gen_server).
-include("include/tplog.hrl").

% API
-export([start_link/3]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% PBFT API for router
-export([handle_proposal/2, handle_network_message/3, is_primary/1]).

-define(SERVER, ?MODULE). % May need to be dynamic if multiple engines run
-define(DEFAULT_TIMEOUT, 5000). % Example timeout for view change

-record(state, {
    node_id :: binary(),
    current_view :: integer(),
    current_leader_id :: binary(),
    sequence_no :: integer(), % Next sequence number to use/expect
    low_watermark :: integer(),
    high_watermark :: integer(), % For windowing, if used
    log = #{} :: map(), % #{SeqNo => #{stage => atom(), message => map(), prepares => map(), commits => map()}}
    pending_blocks = #{} :: map(), % #{Digest => BlockCandidate}
    committee = [] :: list(binary()),
    f :: integer(), % Max faulty nodes
    router_pid :: pid() % To send finalized blocks or other notifications
}).

% API Implementations for gen_server
start_link(NodeId, InitialView, Committee) ->
    % The router_pid is passed in init, so it should be part of the start_link args from the router
    % For self() calls, it's implicitly this gen_server's pid.
    % If this engine needs to call the router, it should be passed in.
    % The current implementation passes self() as RouterPid to init, meaning this engine's PID is RouterPid.
    % This is for the engine to send 'handle_finalized_block' to the router.
    % Let's assume RouterPid is the actual tpnode_consensus_router PID.
    % The start_link in tpnode_consensus_router.erl for local_engine is:
    % {ok, Pid} = local_consensus_engine:start_link(NodeId, CurrentPbftView, CommitteeList),
    % This means the 3rd arg to start_link IS CommitteeList. RouterPid is not passed via start_link.
    % It must be passed IN the init args by the caller (router).
    % The previous definition `start_link(NodeId, InitialView, Committee)` and then using `self()`
    % as RouterPid in `init` means the engine thinks *it* is the router for finalized blocks.
    % This should be corrected: RouterPid should be passed by the actual router.
    % Let's adjust start_link to accept RouterPid.
    % start_link(NodeId, InitialView, Committee, RouterPid) ->
    %    gen_server:start_link(?MODULE, [NodeId, InitialView, Committee, RouterPid], []).
    % And router calls: local_consensus_engine:start_link(NodeId, View, Committee, self())
    % For now, I will stick to the existing start_link/3 and init/1 pattern where RouterPid is self()
    % as it's for this engine to send messages to the router (itself in this case, if router is also this).
    % The task is to send {record_activity, ...} to self, and then call tpnode_mass_manager.

    gen_server:start_link(?MODULE, [NodeId, InitialView, Committee, self()], []).

init([NodeId, InitialView, Committee, RouterPid]) ->
    ?LOG_INFO("Local PBFT Engine starting for Node: ~p, View: ~p, Committee: ~p", [NodeId, InitialView, Committee]),
    F = (length(Committee) - 1) div 3,
    LeaderId = determine_leader(InitialView, Committee),
    State = #state{
        node_id = NodeId,
        current_view = InitialView,
        current_leader_id = LeaderId,
        sequence_no = 0,
        low_watermark = 0,
        high_watermark = 100, % Example, adjust as needed
        log = #{},
        pending_blocks = #{},
        committee = Committee,
        f = F,
        router_pid = RouterPid
    },
    ?LOG_INFO("Local PBFT Engine initialized. NodeId: ~p, Leader: ~p, f: ~p", [NodeId, LeaderId, F]),
    % Start a timer if this node is not the leader, to check for leader activity
    if NodeId /= LeaderId ->
        erlang:send_after(?DEFAULT_TIMEOUT, self(), {check_leader_activity, InitialView});
       true ->
        ok
    end,
    {ok, State}.

% API for router (will be called via gen_server:call/cast)
handle_proposal(State = #state{node_id = NodeId, current_leader_id = LeaderId, sequence_no = SeqNo, current_view = View, committee = Committee, pending_blocks = PBlocks}, BlockCandidate) ->
    if NodeId == LeaderId ->
        T1 = erlang:monotonic_time(),
        ?LOG_INFO("Node ~p (Leader) handling proposal for SeqNo: ~p, View: ~p", [NodeId, SeqNo, View]),
        BlockDigest = crypto:hash(sha256, term_to_binary(BlockCandidate)), % Define digest
        PrePrepareMsg = #{
            tag => pre_prepare,
            view => View,
            seq_no => SeqNo,
            digest => BlockDigest,
            block => BlockCandidate % Include block for now
        },
        NewLogEntry = #{stage => pre_prepared, message => PrePrepareMsg, prepares => #{}, commits => #{}},
        broadcast_to_committee(Committee, {pbft_local, PrePrepareMsg}, NodeId),
        T2 = erlang:monotonic_time(),
        ?LOG_DEBUG("Leader ~p processed proposal S~p,V~p in ~p ms", [NodeId, SeqNo, View, erlang:convert_time_unit(T2-T1, native, milliseconds)]),
        {ok, State#state{
            sequence_no = SeqNo + 1,
            log = maps:put(SeqNo, NewLogEntry, State#state.log),
            pending_blocks = maps:put(BlockDigest, BlockCandidate, PBlocks)
        }};
       true ->
        ?LOG_WARNING("Node ~p received proposal but is not leader (~p). Ignoring.", [NodeId, LeaderId]),
        {error_not_leader, State}
    end.

handle_network_message(State = #state{node_id = NodeId, current_view = View, f = F, log = Log, committee = Committee, pending_blocks = PBlocks, router_pid = RouterPid}, PBFT_Message, FromNodeId) ->
    T_start_net_msg = erlang:monotonic_time(),
    ?LOG_DEBUG("Node ~p received PBFT message: ~p from ~p", [NodeId, PBFT_Message, FromNodeId]),
    case validate_pbft_message(PBFT_Message, FromNodeId, State) of
        ok ->
            Tag = maps:get(tag, PBFT_Message),
            MsgView = maps:get(view, PBFT_Message),
            MsgSeqNo = maps:get(seq_no, PBFT_Message),
            MsgDigest = maps:get(digest, PBFT_Message, undefined),

            NewState = case Tag of
                pre_prepare when FromNodeId == State#state.current_leader_id ->
                    ?LOG_INFO("Node ~p received PRE-PREPARE for S~p, V~p from leader ~p", [NodeId, MsgSeqNo, MsgView, FromNodeId]),
                    Block = maps:get(block, PBFT_Message), % This is BlockCandidate
                    ActualDigest = maps:get(digest, PBFT_Message), % This is Digest of BlockCandidate
                    CalculatedDigest = crypto:hash(sha256, term_to_binary(Block)),
                    if CalculatedDigest == ActualDigest ->
                        T_pre_prepare_start = erlang:monotonic_time(),
                        LogEntry = maps:get(MsgSeqNo, Log, #{}),
                        UpdatedLogEntry = LogEntry#{stage => pre_prepared, message => PBFT_Message, block_candidate => Block, prepares => #{}, commits => #{}},
                        PrepareMsg = #{tag => prepare, view => MsgView, seq_no => MsgSeqNo, digest => ActualDigest, node_id => NodeId},
                        broadcast_to_committee(Committee, {pbft_local, PrepareMsg}, NodeId),
                        % Activity recording for PREPARE broadcast (effectively, pre-prepared this block)
                        gen_server:cast(self(), {record_activity, prepared_block, ActualDigest}),
                        T_pre_prepare_end = erlang:monotonic_time(),
                        ?LOG_DEBUG("Node ~p: PRE-PREPARE S~p,V~p processing took ~p ms", [NodeId, MsgSeqNo, MsgView, erlang:convert_time_unit(T_pre_prepare_end - T_pre_prepare_start, native, milliseconds)]),
                        State#state{
                            log = maps:put(MsgSeqNo, UpdatedLogEntry, Log),
                            pending_blocks = maps:put(ActualDigest, Block, PBlocks) % Store BlockCandidate by its digest
                        };
                       true ->
                        ?LOG_WARNING("PRE-PREPARE digest mismatch for S~p. Ignoring. Calculated ~p, Got ~p", [MsgSeqNo, CalculatedDigest, ActualDigest]),
                        State
                    end;

                prepare ->
                    LogEntry = maps:get(MsgSeqNo, Log, undefined),
                    case LogEntry of
                        #{stage := Stage, message := #{digest := LogDigest}, prepares := Prepares0} when Stage == pre_prepared orelse Stage == prepared, MsgDigest == LogDigest ->
                            ?LOG_INFO("Node ~p received PREPARE for S~p, V~p from ~p", [NodeId, MsgSeqNo, MsgView, FromNodeId]),
                            Prepares = maps:put(FromNodeId, PBFT_Message, Prepares0),
                            UpdatedLogEntry = LogEntry#{prepares => Prepares},
                            NumPrepares = maps:size(Prepares) + 1, % +1 for self pre-prepare/prepare implied
                            if NumPrepares >= (2 * F + 1) andalso Stage == pre_prepared ->
                                T_prepare_start = erlang:monotonic_time(),
                                ?LOG_INFO("Node ~p has 2f+1 PREPAREs for S~p, V~p Digest ~p. Broadcasting COMMIT.", [NodeId, MsgSeqNo, MsgView, MsgDigest]),
                                CommitMsg = #{tag => commit, view => MsgView, seq_no => MsgSeqNo, digest => MsgDigest, node_id => NodeId},
                                broadcast_to_committee(Committee, {pbft_local, CommitMsg}, NodeId),
                                % Activity recording for COMMIT broadcast
                                gen_server:cast(self(), {record_activity, committed_vote, MsgDigest}),
                                T_prepare_end = erlang:monotonic_time(),
                                ?LOG_DEBUG("Node ~p: PREPARE S~p,V~p processing (sent COMMIT) took ~p ms", [NodeId, MsgSeqNo, MsgView, erlang:convert_time_unit(T_prepare_end - T_prepare_start, native, milliseconds)]),
                                State#state{log = maps:put(MsgSeqNo, UpdatedLogEntry#{stage => prepared}, Log)};
                               true ->
                                State#state{log = maps:put(MsgSeqNo, UpdatedLogEntry, Log)}
                            end;
                        _ ->
                            ?LOG_WARNING("Node ~p received PREPARE for S~p, but no matching pre-prepare or digest mismatch. Log: ~p", [NodeId, MsgSeqNo, LogEntry]),
                            State
                    end;

                commit ->
                    LogEntry = maps:get(MsgSeqNo, Log, undefined),
                     case LogEntry of
                        #{stage := Stage, message := #{digest := LogDigest}, commits := Commits0} when (Stage == prepared orelse Stage == committed), MsgDigest == LogDigest ->
                            ?LOG_INFO("Node ~p received COMMIT for S~p, V~p from ~p", [NodeId, MsgSeqNo, MsgView, FromNodeId]),
                            Commits = maps:put(FromNodeId, PBFT_Message, Commits0),
                            UpdatedLogEntry = LogEntry#{commits => Commits},
                            NumCommits = maps:size(Commits) + 1, % +1 for self commit implied
                            if NumCommits >= (2 * F + 1) andalso Stage == prepared ->
                                T_commit_start = erlang:monotonic_time(),
                                ?LOG_INFO("Node ~p has 2f+1 COMMITs for S~p, V~p Digest ~p. Block finalized.", [NodeId, MsgSeqNo, MsgView, MsgDigest]),
                                FinalBlock = maps:get(MsgDigest, PBlocks), % Retrieve block
                                % Notify router about the finalized block
                                gen_server:cast(RouterPid, {handle_finalized_block, ?MODULE, FinalBlock, MsgSeqNo}),
                                % TODO: Advance low_watermark, garbage collect log
                                T_commit_end = erlang:monotonic_time(),
                                ?LOG_DEBUG("Node ~p: COMMIT S~p,V~p processing (finalized) took ~p ms", [NodeId, MsgSeqNo, MsgView, erlang:convert_time_unit(T_commit_end - T_commit_start, native, milliseconds)]),
                                State#state{
                                    log = maps:put(MsgSeqNo, UpdatedLogEntry#{stage => committed}, Log)
                                    % pending_blocks can be cleaned here or by a separate GC mechanism
                                };
                               true ->
                                State#state{log = maps:put(MsgSeqNo, UpdatedLogEntry, Log)}
                            end;
                        _ ->
                            ?LOG_WARNING("Node ~p received COMMIT for S~p, but no matching prepared state or digest mismatch. Log: ~p", [NodeId, MsgSeqNo, LogEntry]),
                            State
                    end;
                view_change ->
                    % Basic view change handling
                    ?LOG_INFO("Node ~p received VIEW-CHANGE from ~p: ~p", [NodeId, FromNodeId, PBFT_Message]),
                    % TODO: Store view_change messages, check for 2f+1, then leader sends NEW-VIEW
                    State;
                new_view ->
                    % Basic new view handling
                    ?LOG_INFO("Node ~p received NEW-VIEW from ~p: ~p", [NodeId, FromNodeId, PBFT_Message]),
                    % TODO: Validate NEW-VIEW, update view and leader, potentially re-process messages
                    State;
                _ ->
                    ?LOG_WARNING("Node ~p received unknown PBFT message tag: ~p", [NodeId, Tag]),
                    State
            end,
            T_end_net_msg = erlang:monotonic_time(),
            ?LOG_DEBUG("Node ~p: Full handle_network_message for S~p,V~p,Tag ~p took ~p ms", [NodeId, MsgSeqNo, MsgView, Tag, erlang:convert_time_unit(T_end_net_msg - T_start_net_msg, native, milliseconds)]),
            {ok, NewState};
        {error, Reason} ->
            ?LOG_WARNING("Invalid PBFT message from ~p: ~p. Reason: ~p", [FromNodeId, PBFT_Message, Reason]),
            {error_invalid_message, State}
    end.

is_primary(State = #state{node_id = NodeId, current_leader_id = LeaderId}) ->
    {NodeId == LeaderId, State}.

% gen_server Callbacks
handle_call({handle_proposal, BlockCandidate}, _From, State) ->
    {Result, NewState} = handle_proposal(State, BlockCandidate),
    {reply, Result, NewState};

handle_call(is_primary, _From, State) ->
    {Result, NewState} = is_primary(State),
    {reply, Result, NewState};

handle_call(Msg, _From, State) ->
    ?LOG_WARNING("Unhandled call in local_consensus_engine: ~p", [Msg]),
    {reply, {error, unhandled_call}, State}.

handle_cast({record_activity, ActivityType, Data}, State = #state{node_id = NodeId}) ->
    tpnode_mass_manager:record_activity(NodeId, ActivityType, Data),
    {noreply, State};

handle_cast({handle_network_message, PBFT_Message, FromNodeId}, State) ->
    {_Result, NewState} = handle_network_message(State, PBFT_Message, FromNodeId),
    {noreply, NewState};

handle_cast(Msg, State) ->
    ?LOG_WARNING("Unhandled cast in local_consensus_engine: ~p", [Msg]),
    {noreply, State}.

handle_info({check_leader_activity, ExpectedView}, State = #state{current_view = CurrentView, node_id = NodeId}) ->
    if CurrentView == ExpectedView andalso NodeId /= State#state.current_leader_id ->
        T_vc_start = erlang:monotonic_time(),
        % This is a very basic check. Real PBFT would check if messages are progressing.
        ?LOG_WARNING("Node ~p timeout waiting for leader activity in View ~p. Initiating view change.", [NodeId, CurrentView]),
        ViewChangeMsg = #{
            tag => view_change,
            view => CurrentView + 1,
            seq_no_checkpoint => State#state.low_watermark, % Last stable checkpoint
            checkpoints => #{}, % Collection of 2f+1 signed checkpoint messages (not implemented yet)
            node_id => NodeId
        },
        broadcast_to_committee(State#state.committee, {pbft_local, ViewChangeMsg}, NodeId),
        % TODO: Transition to a "waiting for view change" state
        T_vc_end = erlang:monotonic_time(),
        ?LOG_INFO("Node ~p: View change initiated for V~p took ~p ms", [NodeId, CurrentView + 1, erlang:convert_time_unit(T_vc_end - T_vc_start, native, milliseconds)]),
        {noreply, State#state{current_view = CurrentView + 1, current_leader_id = determine_leader(CurrentView+1, State#state.committee)}}; % Optimistically update
       true->
        {noreply, State}
    end;

handle_info(Info, State) ->
    ?LOG_WARNING("Unhandled info in local_consensus_engine: ~p", [Info]),
    {noreply, State}.

terminate(Reason, State = #state{}) ->
    ?LOG_INFO("Local PBFT Engine terminating. Reason: ~p, State: ~p", [Reason, State]),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

% Helper functions
determine_leader(View, Committee) when is_list(Committee), length(Committee) > 0 ->
    Index = (View rem length(Committee)) + 1,
    lists:nth(Index, Committee).

broadcast_to_committee(Committee, Message, FromNodeId) ->
    % In a real system, Committee members might be PIDs or need lookup for tpic2
    % For now, assume Committee contains routable NodeIds for tpic2
    lists:foreach(
        fun(PeerNodeId) ->
            if PeerNodeId /= FromNodeId -> % Don't send to self
                % TPIC2 needs a target, which might be the NodeId itself if tpic2 is configured for that
                % The message is already wrapped with {pbft_local, _}
                % The channel for local consensus could be <<"pbft_local_consensus">>
                % Or we rely on tpic2's general routing if PeerNodeId is a global identifier.
                % Let's assume tpic2 can route based on NodeId to the correct process.
                % The actual tpic2 channel/topic might be layer-specific.
                tpic2:cast(PeerNodeId, Message); % This assumes PeerNodeId is a routable tpic2 destination
            true -> ok
            end
        end,
        Committee
    ).

validate_pbft_message(Message, FromNodeId, State = #state{current_view = View, committee = Committee, f = F}) ->
    % Basic validation. Real PBFT needs more (signatures, sequence windows, etc.)
    try
        Tag = maps:get(tag, Message),
        MsgView = maps:get(view, Message),
        _MsgSeqNo = maps:get(seq_no, Message),

        % Check if sender is part of the committee
        true = lists:member(FromNodeId, Committee),

        % Check view (allowing for view_change messages for next view)
        true = (MsgView == View) orelse (Tag == view_change andalso MsgView == View + 1) orelse (Tag == new_view andalso MsgView == View),

        % Further checks based on tag
        case Tag of
            pre_prepare ->
                true = FromNodeId == State#state.current_leader_id;
            _ -> ok
        end,
        ok
    catch
        _:Reason -> {error, Reason}
    end.
