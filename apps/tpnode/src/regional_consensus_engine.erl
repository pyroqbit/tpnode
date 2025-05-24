-module(regional_consensus_engine).
-behaviour(gen_server).
-include("include/tplog.hrl").

% API
-export([start_link/3]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% API for router (to be called via gen_server:call/cast by router)
% These functions are not directly exported but are handled by handle_call/handle_cast
% -export([handle_proposal/2, handle_network_message/3, is_primary/1]).


-record(state, {
    node_id :: binary(),
    committee = [] :: list(binary()),
    router_pid :: pid()
}).

% API Implementations for gen_server
start_link(NodeId, Committee, RouterPid) ->
    gen_server:start_link(?MODULE, [NodeId, Committee, RouterPid], []).

init([NodeId, Committee, RouterPid]) ->
    ?LOG_INFO("Regional Consensus Engine starting for Node: ~p, Committee: ~p", [NodeId, Committee]),
    State = #state{
        node_id = NodeId,
        committee = Committee,
        router_pid = RouterPid
    },
    ?LOG_INFO("Regional Consensus Engine initialized. NodeId: ~p", [NodeId]),
    {ok, State}.

% gen_server Callbacks
handle_call({handle_proposal, BlockCandidate}, _From, State = #state{node_id = NodeId}) ->
    ?LOG_INFO("Regional engine (~p) received proposal: ~p", [NodeId, BlockCandidate]),
    % Record dummy activity for proposal
    tpnode_mass_manager:record_activity(NodeId, regional_proposal_received, #{block_candidate_digest => crypto:hash(sha256, term_to_binary(BlockCandidate))}),
    {reply, {ok, proposal_logged_regional}, State};

handle_call(is_primary, _From, State = #state{node_id = NodeId, committee = Committee}) ->
    ?LOG_INFO("Regional engine (~p) is_primary called.", [NodeId]),
    % Record dummy activity for is_primary check
    tpnode_mass_manager:record_activity(NodeId, regional_is_primary_checked, #{}),
    IsPrimary = case Committee of
        [LeaderNodeId | _] when NodeId == LeaderNodeId -> true;
        [] -> ?LOG_WARNING("Regional committee is empty for node ~p, defaulting is_primary to false", [NodeId]), false;
        _ -> false
    end,
    {reply, IsPrimary, State};

handle_call(Msg, _From, State = #state{node_id = NodeId}) ->
    ?LOG_WARNING("Regional engine (~p) unhandled call: ~p", [NodeId, Msg]),
    {reply, {error, unhandled_call}, State}.


handle_cast({handle_network_message, Message, FromNode}, State = #state{node_id = NodeId}) ->
    ?LOG_INFO("Regional engine (~p) received message: ~p from ~p", [NodeId, Message, FromNode]),
    % Record dummy activity for network message
    tpnode_mass_manager:record_activity(NodeId, regional_network_message_received, #{message_tag => maps:get(tag, Message, unknown)}),
    {noreply, State};

handle_cast(Msg, State = #state{node_id = NodeId}) ->
    ?LOG_WARNING("Regional engine (~p) unhandled cast: ~p", [NodeId, Msg]),
    {noreply, State}.


handle_info(Info, State = #state{node_id = NodeId}) ->
    ?LOG_WARNING("Regional engine (~p) unhandled info: ~p", [NodeId, Info]),
    {noreply, State}.

terminate(Reason, State = #state{node_id = NodeId}) ->
    ?LOG_INFO("Regional Consensus Engine (~p) terminating. Reason: ~p", [NodeId, Reason]),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.
