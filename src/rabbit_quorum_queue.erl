%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2018 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_quorum_queue).

-export([init_state/2, handle_event/2]).
-export([declare/1, recover/1, stop/1, delete/4, delete_immediately/1]).
-export([info/1, info/2, stat/1, infos/1]).
-export([ack/3, reject/4, basic_get/4, basic_consume/9, basic_cancel/4]).
-export([purge/1]).
-export([stateless_deliver/2, deliver/3]).
-export([dead_letter_publish/5]).
-export([queue_name/1]).
-export([cluster_state/1, status/2]).
-export([cancel_customer_handler/3, cancel_customer/3]).
-export([become_leader/2, update_metrics/2]).
-export([rpc_delete_metrics/1]).
-export([format/1]).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-type ra_node_id() :: {Name :: atom(), Node :: node()}.
-type msg_id() :: non_neg_integer().
-type qmsg() :: {rabbit_types:r('queue'), pid(), msg_id(), boolean(), rabbit_types:message()}.

-spec handle_event({'ra_event', ra_node_id(), any()}, ra_fifo_client:state()) ->
                          {'internal', Correlators :: [term()], ra_fifo_client:state()} |
                          {ra_fifo:client_msg(), ra_fifo_client:state()}.
-spec declare(rabbit_types:amqqueue()) -> {'new', rabbit_types:amqqueue(), ra_fifo_client:state()}.
-spec recover([rabbit_types:amqqueue()]) -> [rabbit_types:amqqueue() |
                                             {'absent', rabbit_types:amqqueue(), atom()}].
-spec stop(rabbit_types:vhost()) -> 'ok'.
-spec delete(rabbit_types:amqqueue(), boolean(), boolean(), rabbit_types:username()) ->
                    {'ok', QLen :: non_neg_integer()}.
-spec ack(rabbit_types:ctag(), [msg_id()], ra_fifo_client:state()) ->
                 {'ok', ra_fifo_client:state()}.
-spec reject(Confirm :: boolean(), rabbit_types:ctag(), [msg_id()], ra_fifo_client:state()) ->
                    {'ok', ra_fifo_client:state()}.
-spec basic_get(rabbit_types:amqqueue(), NoAck :: boolean(), rabbit_types:ctag(),
                ra_fifo_client:state()) ->
                       {'ok', 'empty', ra_fifo_client:state()} |
                       {'ok', QLen :: non_neg_integer(), qmsg(), ra_fifo_client:state()}.
-spec basic_consume(rabbit_types:amqqueue(), NoAck :: boolean(), ChPid :: pid(),
                    ConsumerPrefetchCount :: non_neg_integer(), rabbit_types:ctag(),
                    ExclusiveConsume :: boolean(), Args :: rabbit_framing:amqp_table(),
                    any(), ra_fifo_client:state()) -> {'ok', ra_fifo_client:state()}.
-spec basic_cancel(rabbit_types:ctag(), ChPid :: pid(), any(), ra_fifo_client:state()) ->
                          {'ok', ra_fifo_client:state()}.
-spec stateless_deliver(ra_node_id(), rabbit_types:delivery()) -> 'ok'.
-spec deliver(Confirm :: boolean(), rabbit_types:delivery(), ra_fifo_client:state()) ->
                     ra_fifo_client:state().
-spec info(rabbit_types:amqqueue()) -> rabbit_types:infos().
-spec info(rabbit_types:amqqueue(), rabbit_types:info_keys()) -> rabbit_types:infos().
-spec infos(rabbit_types:r('queue')) -> rabbit_types:infos().
-spec stat(rabbit_types:amqqueue()) -> {'ok', non_neg_integer(), non_neg_integer()}.
-spec cluster_state(Name :: atom()) -> 'down' | 'recovering' | 'running'.
-spec status(rabbit_types:vhost(), Name :: atom()) -> rabbit_types:infos().

-define(STATISTICS_KEYS,
        [policy,
         operator_policy,
         effective_policy_definition,
         consumers,
         consumer_utilisation,
         memory,
         state,
         garbage_collection,
         leader,
         online,
         members
        ]).

%%----------------------------------------------------------------------------

-spec init_state(ra_node_id(), rabbit_types:r('queue')) ->
    ra_fifo_client:state().
init_state({Name, _} = Id, QName) ->
    {ok, SoftLimit} = application:get_env(rabbit, quorum_commands_soft_limit),
    ra_fifo_client:init(QName, [Id], SoftLimit,
                        fun() -> credit_flow:block(Name), ok end,
                        fun() -> credit_flow:unblock(Name), ok end).

handle_event({ra_event, From, Evt}, FState) ->
    ra_fifo_client:handle_ra_event(From, Evt, FState).

declare(#amqqueue{name = QName,
                  durable = Durable,
                  auto_delete = AutoDelete,
                  arguments = Arguments,
                  options = Opts} = Q) ->
    ActingUser = maps:get(user, Opts, ?UNKNOWN_USER),
    check_invalid_arguments(QName, Arguments),
    check_auto_delete(Q),
    check_exclusive(Q),
    RaName = qname_to_rname(QName),
    Id = {RaName, node()},
    Nodes = rabbit_mnesia:cluster_nodes(all),
    NewQ0 = Q#amqqueue{pid = Id,
                      quorum_nodes = Nodes},
    case rabbit_amqqueue:internal_declare(NewQ0, false) of
        {created, NewQ} ->
            RaMachine = ra_machine(NewQ),
            case ra:start_cluster(RaName, RaMachine,
                                  [{RaName, Node} || Node <- Nodes]) of
                {ok, _, _} ->
                    FState = init_state(Id, QName),
                    %% TODO does the quorum queue receive the `force_event_refresh`?
                    %% what do we do with it?
                    rabbit_event:notify(queue_created,
                                        [{name, QName},
                                         {durable, Durable},
                                         {auto_delete, AutoDelete},
                                         {arguments, Arguments},
                                         {user_who_performed_action, ActingUser}]),
                    {new, NewQ, FState};
                {error, Error} ->
                    _ = rabbit_amqqueue:internal_delete(QName, ActingUser),
                    rabbit_misc:protocol_error(internal_error,
                                               "Cannot declare a queue '~s' on node '~s': ~255p",
                                               [rabbit_misc:rs(QName), node(), Error])
            end;
        {existing, _} = Ex ->
            Ex
    end.

ra_machine(Q = #amqqueue{name = QName}) ->
    {module, ra_fifo,
     #{dead_letter_handler => dlx_mfa(Q),
       cancel_customer_handler => {?MODULE, cancel_customer, [QName]},
       become_leader_handler => {?MODULE, become_leader, [QName]},
       metrics_handler => {?MODULE, update_metrics, [QName]}}}.

cancel_customer_handler(QName, {ConsumerTag, ChPid}, _Name) ->
    Node = node(ChPid),
    % QName = queue_name(Name),
    case Node == node() of
        true -> cancel_customer(QName, ChPid, ConsumerTag);
        false -> rabbit_misc:rpc_call(Node, rabbit_quorum_queue,
                                      cancel_customer,
                                      [QName, ChPid, ConsumerTag])
    end.

cancel_customer(QName, ChPid, ConsumerTag) ->
    rabbit_core_metrics:consumer_deleted(ChPid, ConsumerTag, QName),
    rabbit_event:notify(consumer_deleted,
                        [{consumer_tag, ConsumerTag},
                         {channel,      ChPid},
                         {queue,        QName},
                         {user_who_performed_action, ?INTERNAL_USER}]).

become_leader(QName, Name) ->
    % QName = queue_name(Name),
    Fun = fun(Q1) -> Q1#amqqueue{pid = {Name, node()}} end,
    %% as this function is called synchronously when a ra node becomes leader
    %% we need to ensure there is no chance of blocking as else the ra node
    %% cannot establish it's leadership
    spawn(fun() ->
                  rabbit_misc:execute_mnesia_transaction(
                    fun() -> rabbit_amqqueue:update(QName, Fun) end),
                  case rabbit_amqqueue:lookup(QName) of
                      {ok, #amqqueue{quorum_nodes = Nodes}} ->
                          [rpc:call(Node, ?MODULE, rpc_delete_metrics, [QName])
                           || Node <- Nodes, Node =/= node()];
                      _ ->
                          ok
                  end
          end).

rpc_delete_metrics(QName) ->
    ets:delete(queue_coarse_metrics, QName),
    ets:delete(queue_metrics, QName),
    ok.

update_metrics(QName, {Name, MR, MU, M, C}) ->
    R = reductions(Name),
    rabbit_core_metrics:queue_stats(QName, MR, MU, M, R),
    Infos = [{consumers, C} | infos(QName)],
    rabbit_core_metrics:queue_stats(QName, Infos),
    rabbit_event:notify(queue_stats, Infos ++ [{name, QName},
                                               {messages, M},
                                               {messages_ready, MR},
                                               {messages_unacknowledged, MU},
                                               {reductions, R}]).

reductions(Name) ->
    try
        {reductions, R} = process_info(whereis(Name), reductions),
        R
    catch
        error:badarg ->
            0
    end.

recover(Queues) ->
    [begin
         case ra:restart_node({Name, node()}) of
             ok ->
                 % queue was restarted, good
                 ok;
             {error, Err}
               when Err == not_started orelse
                    Err == name_not_registered ->
                 % queue was never started on this node
                 % so needs to be started from scratch.
                 Machine = ra_machine(Q),
                 RaNodes = [{Name, Node} || Node <- Nodes],
                 % TODO: should we crash the vhost here or just log the error
                 % and continue?
                 ok = ra:start_node(Name, {Name, node()},
                                    Machine, RaNodes)
         end,
         {_, Q} = rabbit_amqqueue:internal_declare(Q, true),
         Q
     end || #amqqueue{pid = {Name, _},
                      quorum_nodes = Nodes} = Q <- Queues].

stop(VHost) ->
    _ = [ra:stop_node(Pid) || #amqqueue{pid = Pid} <- find_quorum_queues(VHost)],
    ok.

delete(#amqqueue{ type = quorum, pid = {Name, _}, name = QName, quorum_nodes = QNodes},
       _IfUnused, _IfEmpty, ActingUser) ->
    %% TODO Quorum queue needs to support consumer tracking for IfUnused
    Msgs = quorum_messages(Name),
    _ = rabbit_amqqueue:internal_delete(QName, ActingUser),
    {ok, Leader} = ra:delete_cluster([{Name, Node} || Node <- QNodes]),
    MRef = erlang:monitor(process, Leader),
    receive
        {'DOWN', MRef, process, _, _} ->
            ok
    end,
    rabbit_core_metrics:queue_deleted(QName),
    {ok, Msgs}.

delete_immediately({Name, _} = QPid) ->
    QName = queue_name(Name),
    _ = rabbit_amqqueue:internal_delete(QName, ?INTERNAL_USER),
    ok = ra:delete_cluster([QPid]),
    rabbit_core_metrics:queue_deleted(QName),
    ok.

ack(CTag, MsgIds, FState) ->
    ra_fifo_client:settle(quorum_ctag(CTag), MsgIds, FState).

reject(true, CTag, MsgIds, FState) ->
    ra_fifo_client:return(quorum_ctag(CTag), MsgIds, FState);
reject(false, CTag, MsgIds, FState) ->
    ra_fifo_client:discard(quorum_ctag(CTag), MsgIds, FState).

basic_get(#amqqueue{name = QName, pid = {Name, _} = Id, type = quorum}, NoAck,
          CTag0, FState0) ->
    CTag = quorum_ctag(CTag0),
    Settlement = case NoAck of
                     true ->
                         settled;
                     false ->
                         unsettled
                 end,
    case ra_fifo_client:dequeue(CTag, Settlement, FState0) of
        {ok, empty, FState} ->
            {ok, empty, FState};
        {ok, {MsgId, {MsgHeader, Msg}}, FState} ->
            IsDelivered = maps:is_key(delivery_count, MsgHeader),
            {ok, quorum_messages(Name), {QName, Id, MsgId, IsDelivered, Msg}, FState}
    end.

basic_consume(#amqqueue{name = QName, type = quorum}, NoAck, ChPid,
              ConsumerPrefetchCount, ConsumerTag, ExclusiveConsume, Args, OkMsg, FState0) ->
    maybe_send_reply(ChPid, OkMsg),
    %% A prefetch count of 0 means no limitation, let's make it into something large for ra
    Prefetch = case ConsumerPrefetchCount of
                   0 -> 2000;
                   Other -> Other
               end,
    {ok, FState} = ra_fifo_client:checkout(quorum_ctag(ConsumerTag), Prefetch, FState0),
    %% TODO maybe needs to be handled by ra? how can we manage the consumer deleted?
    rabbit_core_metrics:consumer_created(ChPid, ConsumerTag, ExclusiveConsume,
                                         not NoAck, QName, ConsumerPrefetchCount, Args),
    {ok, FState}.

basic_cancel(ConsumerTag, ChPid, OkMsg, FState0) ->
    maybe_send_reply(ChPid, OkMsg),
    ra_fifo_client:cancel_checkout(quorum_ctag(ConsumerTag), FState0).

stateless_deliver({Name, _} = Pid, Delivery) ->
    ok = ra_fifo_client:untracked_enqueue(Name, [Pid],
                                          Delivery#delivery.message).

deliver(false, Delivery, FState0) ->
    ra_fifo_client:enqueue(Delivery#delivery.message, FState0);
deliver(true, Delivery, FState0) ->
    ra_fifo_client:enqueue(Delivery#delivery.msg_seq_no,
                           Delivery#delivery.message, FState0).

info(Q) ->
    info(Q, [name, durable, auto_delete, arguments, pid, state, messages,
             messages_ready, messages_unacknowledged]).

infos(QName) ->
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} ->
            info(Q, ?STATISTICS_KEYS);
        {error, not_found} ->
            []
    end.

info(Q, Items) ->
    [{Item, i(Item, Q)} || Item <- Items].

stat(_Q) ->
    {ok, 0, 0}.  %% TODO length, consumers count

purge(Node) ->
    ra_fifo_client:purge(Node).

cluster_state(Name) ->
    case whereis(Name) of
        undefined -> down;
        _ ->
            case ets:lookup(ra_state, Name) of
                [{_, recover}] -> recovering;
                _ -> running
            end
    end.

status(Vhost, QueueName) ->
    %% Handle not found queues
    QName = #resource{virtual_host = Vhost, name = QueueName, kind = queue},
    RName = qname_to_rname(QName),
    case rabbit_amqqueue:lookup(QName) of
        {ok, #amqqueue{pid = {_, Leader}, quorum_nodes = Nodes}} ->
            Info = [{leader, Leader}, {members, Nodes}],
            case ets:lookup(ra_state, RName) of
                [{_, State}] ->
                    [{local_state, State} | Info];
                [] ->
                    Info
            end;
        {error, not_found} = E ->
            E
    end.

%%----------------------------------------------------------------------------
dlx_mfa(#amqqueue{name = Resource} = Q) ->
    #resource{virtual_host = VHost} = Resource,
    DLX = init_dlx(args_policy_lookup(<<"dead-letter-exchange">>, fun res_arg/2, Q), Q),
    DLXRKey = args_policy_lookup(<<"dead-letter-routing-key">>, fun res_arg/2, Q),
    {?MODULE, dead_letter_publish, [VHost, DLX, DLXRKey, Q#amqqueue.name]}.

init_dlx(undefined, _Q) ->
    undefined;
init_dlx(DLX, #amqqueue{name = QName}) ->
    rabbit_misc:r(QName, exchange, DLX).

res_arg(_PolVal, ArgVal) -> ArgVal.

args_policy_lookup(Name, Resolve, Q = #amqqueue{arguments = Args}) ->
    AName = <<"x-", Name/binary>>,
    case {rabbit_policy:get(Name, Q), rabbit_misc:table_lookup(Args, AName)} of
        {undefined, undefined}       -> undefined;
        {undefined, {_Type, Val}}    -> Val;
        {Val,       undefined}       -> Val;
        {PolVal,    {_Type, ArgVal}} -> Resolve(PolVal, ArgVal)
    end.

dead_letter_publish(_, undefined, _, _, _) ->
    ok;
dead_letter_publish(VHost, X, RK, QName, ReasonMsgs) ->
    rabbit_vhost_dead_letter:publish(VHost, X, RK, QName, ReasonMsgs).

%% TODO escape hack
qname_to_rname(#resource{virtual_host = <<"/">>, name = Name}) ->
    erlang:binary_to_atom(<<"%2F_", Name/binary>>, utf8);
qname_to_rname(#resource{virtual_host = VHost, name = Name}) ->
    erlang:binary_to_atom(<<VHost/binary, "_", Name/binary>>, utf8).

find_quorum_queues(VHost) ->
    Node = node(),
    mnesia:async_dirty(
      fun () ->
              qlc:e(qlc:q([Q || Q = #amqqueue{vhost = VH,
                                              pid  = Pid,
                                              type = quorum}
                                    <- mnesia:table(rabbit_durable_queue),
                                VH =:= VHost,
                                qnode(Pid) == Node]))
      end).

i(name,               #amqqueue{name               = Name}) -> Name;
i(durable,            #amqqueue{durable            = Dur}) -> Dur;
i(auto_delete,        #amqqueue{auto_delete        = AD}) -> AD;
i(arguments,          #amqqueue{arguments          = Args}) -> Args;
i(pid,                #amqqueue{pid                = {Name, _}}) -> whereis(Name);
i(messages,           #amqqueue{pid                = {Name, _}}) ->
    quorum_messages(Name);
i(messages_ready,     #amqqueue{name               = QName}) ->
    case ets:lookup(queue_coarse_metrics, QName) of
        [{_, MR, _, _, _}] ->
            MR;
        [] ->
            0
    end;
i(messages_unacknowledged, #amqqueue{name          = QName}) ->
    case ets:lookup(queue_coarse_metrics, QName) of
        [{_, _, MU, _, _}] ->
            MU;
        [] ->
            0
    end;
i(policy, Q) ->
    case rabbit_policy:name(Q) of
        none   -> '';
        Policy -> Policy
    end;
i(operator_policy, Q) ->
    case rabbit_policy:name_op(Q) of
        none   -> '';
        Policy -> Policy
    end;
i(effective_policy_definition, Q) ->
    case rabbit_policy:effective_definition(Q) of
        undefined -> [];
        Def       -> Def
    end;
i(consumers,     #amqqueue{name               = QName}) ->
    case ets:lookup(queue_metrics, QName) of
        [{_, M, _}] ->
            proplists:get_value(consumers, M, 0);
        [] ->
            0
    end;
i(consumer_utilisation, _Q) ->
    %% TODO!
    0;
i(memory, #amqqueue{pid = {Name, _}}) ->
    try
        {memory, M} = process_info(whereis(Name), memory),
        M
    catch
        error:badarg ->
            0
    end;
i(state, #amqqueue{pid = {Name, Node}}) ->
    %% Check against the leader or last known leader
    case rpc:call(Node, ?MODULE, cluster_state, [Name]) of
        {badrpc, _} -> down;
        State -> State
    end;
i(local_state, #amqqueue{pid = {Name, _}}) ->
    case ets:lookup(ra_state, Name) of
        [{_, State}] -> State;
        _ -> not_member
    end;
i(garbage_collection, #amqqueue{pid = {Name, _}}) ->
    try
        rabbit_misc:get_gc_info(whereis(Name))
    catch
        error:badarg ->
            []
    end;
i(members, #amqqueue{quorum_nodes = Nodes}) ->
    Nodes;
i(online, Q) -> online(Q);
i(leader, Q) -> leader(Q);
i(_K, _Q) -> ''.

leader(#amqqueue{pid = {Name, Leader}}) ->
    case is_process_alive(Name, Leader) of
        true -> Leader;
        false -> ''
    end.

online(#amqqueue{quorum_nodes = Nodes,
                 pid = {Name, _Leader}}) ->
    [Node || Node <- Nodes, is_process_alive(Name, Node)].

format(#amqqueue{quorum_nodes = Nodes} = Q) ->
    [{members, Nodes}, {online, online(Q)}, {leader, leader(Q)}].

is_process_alive(Name, Node) ->
    erlang:is_pid(rpc:call(Node, erlang, whereis, [Name])).

quorum_messages(QName) ->
    case ets:lookup(queue_coarse_metrics, QName) of
        [{_, _, _, M, _}] ->
            M;
        [] ->
            0
    end.

quorum_ctag(Int) when is_integer(Int) ->
    integer_to_binary(Int);
quorum_ctag(Other) ->
    Other.

maybe_send_reply(_ChPid, undefined) -> ok;
maybe_send_reply(ChPid, Msg) -> ok = rabbit_channel:send_command(ChPid, Msg).

qnode(QPid) when is_pid(QPid) ->
    node(QPid);
qnode({_, Node}) ->
    Node.

check_invalid_arguments(QueueName, Args) ->
    Keys = [<<"x-expires">>, <<"x-message-ttl">>, <<"x-max-length">>,
            <<"x-max-length-bytes">>, <<"x-max-priority">>, <<"x-overflow">>,
            <<"x-queue-mode">>],
    [case rabbit_misc:table_lookup(Args, Key) of
         undefined -> ok;
         _TypeVal   -> rabbit_misc:protocol_error(
                         precondition_failed,
                         "invalid arg '~s' for ~s",
                         [Key, rabbit_misc:rs(QueueName)])
     end || Key <- Keys],
    ok.

check_auto_delete(#amqqueue{auto_delete = true, name = Name}) ->
    rabbit_misc:protocol_error(
      precondition_failed,
      "invalid property 'auto-delete' for ~s",
      [rabbit_misc:rs(Name)]);
check_auto_delete(_) ->
    ok.

check_exclusive(#amqqueue{exclusive_owner = none}) ->
    ok;
check_exclusive(#amqqueue{name = Name}) ->
    rabbit_misc:protocol_error(
      precondition_failed,
      "invalid property 'exclusive-owner' for ~s",
      [rabbit_misc:rs(Name)]).

queue_name(RaFifoState) ->
    ra_fifo_client:cluster_id(RaFifoState).
