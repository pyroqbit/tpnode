-module(tpnode_layer_bridge).
-include("include/tplog.hrl").

% API
-export([handle_lower_layer_finality/2]).

%% @doc Handles the finality of a block from a lower layer and bridges a summary to the next layer.
%% OriginLayer: The layer where the block was finalized (e.g., local, regional).
%% FinalizedBlockData: A map containing details of the finalized block,
%%                     e.g., #{block_hash => binary(), tx_hashes => list(binary()), height => integer()}.
handle_lower_layer_finality(OriginLayer, FinalizedBlockData) when is_atom(OriginLayer), is_map(FinalizedBlockData) ->
    T_bridge_start = erlang:monotonic_time(),
    ?LOG_INFO("Layer bridge handling finality from ~p. Data: ~p", [OriginLayer, FinalizedBlockData]),
    TargetLayer = determine_target_layer(OriginLayer),

    Res = if TargetLayer == none ->
        ?LOG_INFO("No target layer for summary from ~p. Doing nothing.", [OriginLayer]),
        ok;
       true ->
        SummaryTx = #{
            <<"type">> => <<"layer_summary">>, % Using binaries for keys for consistency if it becomes a real tx
            <<"origin_layer">> => atom_to_binary(OriginLayer, utf8),
            <<"data">> => FinalizedBlockData % This map itself can be part of the tx
        },
        ?LOG_INFO("Bridging summary from ~p to ~p. SummaryTx: ~p", [OriginLayer, TargetLayer, SummaryTx]),
        % The new function submit_proposal_to_layer/2 will be added to tpnode_consensus_router
        tpnode_consensus_router:submit_proposal_to_layer(TargetLayer, SummaryTx)
    end,
    T_bridge_end = erlang:monotonic_time(),
    ?LOG_INFO("handle_lower_layer_finality from ~p to ~p took ~p ms. Result: ~p", 
              [OriginLayer, TargetLayer, erlang:convert_time_unit(T_bridge_end - T_bridge_start, native, milliseconds), Res]),
    ok.

% Internal functions
determine_target_layer(local) -> regional;
determine_target_layer(regional) -> global;
determine_target_layer(global) ->
    % Global layer is the highest, no further target for summaries of its own blocks in this context.
    % It might interact with other global chains, but that's outside this bridge's scope.
    none;
determine_target_layer(_OtherLayer) ->
    ?LOG_WARNING("Cannot determine target layer for unknown origin layer: ~p", [_OtherLayer]),
    none.
