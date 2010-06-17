%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(riak_search_raptor_backend).
-author("John Muellerleile <johnm@basho.com>").
-behavior(riak_search_backend).

-export([start/2,stop/1,index/6,info/5]).
-export([get/2,put/3,list/1,list_bucket/2,delete/2]).
-export([fold/3, drop/1, is_empty/1, toggle_raptor_debug/0, shutdown_raptor/0]).
-export([sync/0, poke/1, raptor_status/0]).

-export([test_fold/0, test_is_empty/0, test_drop/0]).

-include_lib("eunit/include/eunit.hrl").
-include("riak_search.hrl").

% @type state() = term().
-record(state, {partition, conn}).

-define(FOLD_TIMEOUT, 30000).
-define(MAX_HANDOFF_STREAMS, 50).
-define(INFO_TIMEOUT, 5000).

%% @spec start(Partition :: integer(), Config :: proplist()) ->
%%          {ok, state()} | {{error, Reason :: term()}, state()}
%% @doc Start this backend.
start(Partition, _Config) ->
    {ok, Conn} = raptor_conn_sup:new_conn(),
    {ok, #state { partition=Partition, conn=Conn }}.

%% @spec stop(state()) -> ok | {error, Reason :: term()}
stop(#state{conn=Conn}) ->
    raptor_conn:close(Conn),
    ok.

%% @spec put(state(), BKey :: riak_object:bkey(), Val :: binary()) ->
%%         ok | {error, Reason :: term()}
%% @doc Route all commands through the object's value.
put(State, _BKey, ObjBin) ->
    Obj = binary_to_term(ObjBin),
    Command = riak_object:get_value(Obj),
    handle_command(State, Command).

index(Index, Field, Term, Value, Props, State) ->
    Partition = list_to_binary(integer_to_list(State#state.partition)),
    Conn = State#state.conn,
    raptor_conn:index(Conn,
                      list_to_binary(Index),
                      list_to_binary(Field),
                      Term,
                      list_to_binary(Value),
                      Partition,
                      term_to_binary(Props)),
    noreply.

info(Index, Field, Term, Sender, State) ->
    Partition = list_to_binary(integer_to_list(State#state.partition)),
    spawn_link(fun() ->
        {ok, Conn} = raptor_conn_sup:new_conn(),
        try
            {ok, StreamRef} = raptor_conn:info(
                Conn,
                list_to_binary(Index),
                list_to_binary(Field),
                list_to_binary(Term),
                Partition),
            receive_info_results(StreamRef, Sender)
        after
          raptor_conn:close(Conn)
        end
    end),
    noreply.

handle_command(State, {delete_entry, Index, Field, Term, DocId}) ->
    Partition = list_to_binary(integer_to_list(State#state.partition)),
    Conn = State#state.conn,
    raptor_conn:delete_entry(Conn,
                             list_to_binary(Index),
                             list_to_binary(Field),
                             Term,
                             list_to_binary(DocId),
                             Partition),
    ok;

handle_command(State, {init_stream, OutputPid, OutputRef}) ->
    %% Do some handshaking so that we only stream results from one partition/node.
    Partition = State#state.partition,
    OutputPid!{stream_ready, Partition, node(), OutputRef},
    ok;

handle_command(State, {stream, Index, Field, Term, OutputPid, OutputRef, DestPartition, Node, FilterFun}) ->
    spawn(fun() ->
        Partition = list_to_binary(integer_to_list(State#state.partition)),
        case DestPartition == State#state.partition andalso Node == node() of
            true ->
                spawn_link(fun() ->
                                   {ok, Conn} = raptor_conn_sup:new_conn(),
                                   try
                                       {ok, StreamRef} = raptor_conn:stream(
                                                           Conn,
                                                           list_to_binary(Index),
                                                           list_to_binary(Field),
                                                           list_to_binary(Term),
                                                           Partition),
                                       receive_stream_results(StreamRef, OutputPid, OutputRef, FilterFun)
                                   after
                                       raptor_conn:close(Conn)
                                   end end),
                ok;
            false ->
                %% The requester doesn't want results from this node, so
                %% ignore. This is a hack, to get around the fact that
                %% there is no way to send a put or other command to a
                %% specific v-node.
                ignore
        end end),
    ok;

handle_command(_State, {info_test__, _Index, _Field, Term, OutputPid, OutputRef}) ->
    OutputPid ! {info_response, [{Term, node(), 1}], OutputRef},
    ok;


handle_command(State, {info_range, Index, Field, StartTerm, EndTerm, _Size, OutputPid, OutputRef}) ->
    Partition = list_to_binary(integer_to_list(State#state.partition)),
    spawn_link(fun() ->
                       {ok, Conn} = raptor_conn_sup:new_conn(),
                       try
                           {ok, StreamRef} = raptor_conn:info_range(
                                               Conn,
                                               list_to_binary(Index),
                                               list_to_binary(Field),
                                               list_to_binary(StartTerm),
                                               list_to_binary(EndTerm),
                                               Partition),
                           receive_info_range_results(StreamRef, OutputPid, OutputRef)
                       after
                           raptor_conn:close(Conn)
                       end
    end),
    ok;

handle_command(_State, {catalog_query, CatalogQuery, OutputPid, OutputRef}) ->
    spawn_link(fun() ->
                       {ok, Conn} = raptor_conn_sup:new_conn(),
                       try
                           {ok, StreamRef} = raptor_conn:catalog_query(
                                               Conn,
                                               CatalogQuery),
                           receive_catalog_query_results(StreamRef, OutputPid, OutputRef)
                       after
                           raptor_conn:close(Conn)
                       end
    end),
    ok;

handle_command(_State, {command, Command, Arg1, Arg2, Arg3}) ->
    {ok, Conn} = raptor_conn_sup:new_conn(),
    try
        {ok, _StreamRef} = raptor_conn:command(Conn, Command, Arg1, Arg2, Arg3),
        receive
            {command, _ReqId, Response} ->
                io:format("command: Response = ~p~n", [Response]),
                Response;
            Msg ->
                io:format("handle_command/command, unexpected response: Msg = ~p~n", [Msg]),
                Msg
        end
    after
        raptor_conn:close(Conn)
    end;

handle_command(_State, Other) ->
    throw({unexpected_operation, Other}).

receive_stream_results(StreamRef, OutputPid, OutputRef, FilterFun) ->
    receive_stream_results(StreamRef, OutputPid, OutputRef, FilterFun, []).

receive_stream_results(StreamRef, OutputPid, OutputRef, FilterFun, Acc0) ->
    case length(Acc0) > 500 of
        true ->
            io:format("chunk (~p) ~p~n", [length(Acc0), StreamRef]),
            OutputPid ! {result_vec, Acc0, OutputRef},
            Acc = [];
        false ->
            Acc = Acc0
    end,
    receive
        {stream, StreamRef, "$end_of_table", _} ->
            case length(Acc) > 0 of
                true ->
                    OutputPid ! {result_vec, Acc, OutputRef};
                false -> skip
            end,
            OutputPid ! {result, '$end_of_table', OutputRef};
        {stream, StreamRef, Value, Props} ->
            case Props of
                <<"">> ->
                    Props2 = [];
                _ ->
                    Props2 = binary_to_term(Props)
            end,
            case FilterFun(Value, Props2) of
                true ->
                    Acc2 = Acc ++ [{Value, Props2}];
                    %OutputPid ! {result, {Value, Props2}, OutputRef};
                _ ->
                    Acc2 = Acc,
                    skip
            end,
            receive_stream_results(StreamRef, OutputPid, OutputRef, FilterFun, Acc2);
        Msg ->
            io:format("receive_stream_results(~p, ~p, ~p, ~p) -> ~p~n",
                [StreamRef, OutputPid, OutputRef, FilterFun, Msg]),
            OutputPid ! {result, '$end_of_table', OutputRef}
    end,
    ok.

%% receive_stream_results2(StreamRef, OutputPid, OutputRef, FilterFun) ->
%%     receive
%%         {stream, StreamRef, "$end_of_table", _} ->
%%             OutputPid ! {result, '$end_of_table', OutputRef};
%%         {stream, StreamRef, Value, Props} ->
%%             Props2 = binary_to_term(Props),
%%             case FilterFun(Value, Props2) of
%%                 true -> OutputPid ! {result, {Value, Props2}, OutputRef};
%%                 _ -> skip
%%             end,
%%             receive_stream_results(StreamRef, OutputPid, OutputRef, FilterFun);
%%         Msg ->
%%             io:format("receive_stream_results(~p, ~p, ~p, ~p) -> ~p~n",
%%                 [StreamRef, OutputPid, OutputRef, FilterFun, Msg]),
%%             OutputPid ! {result, '$end_of_table', OutputRef}
%%     end,
%%     ok.

receive_info_range_results(StreamRef, OutputPid, OutputRef) ->
    receive_info_range_results(StreamRef, OutputPid, OutputRef, []).
receive_info_range_results(StreamRef, OutputPid, OutputRef, Results) ->
    receive
        {info, StreamRef, "$end_of_info", 0} ->
            OutputPid ! {info_response, Results, OutputRef};
        {info, StreamRef, Term, Count} ->
            receive_info_range_results(StreamRef, OutputPid, OutputRef,
                Results ++ [{Term, node(), Count}]);
        Msg ->
            io:format("receive_info_range_results(~p, ~p, ~p) -> ~p~n",
                [StreamRef, OutputPid, OutputRef, Msg]),
            receive_info_range_results(StreamRef, OutputPid, OutputRef, Results)
    end,
    ok.

receive_info_results(StreamRef, Sender) ->
    receive
        {info, StreamRef, Term, Count} ->
            riak_search_backend:info_response(Sender, Term, node(), Count)
    after
        ?INFO_TIMEOUT ->
            ok
    end,
    ok.

receive_catalog_query_results(StreamRef, OutputPid, OutputRef) ->
    receive
        {catalog_query, _ReqId, "$end_of_results", _, _, _, _} ->
            io:format("catalog_query_results -> $end_of_results~n", []),
            OutputPid ! {catalog_query_response, done, OutputRef};
        {catalog_query, StreamRef, Partition, Index,
                        Field, Term, JSONProps} ->
            OutputPid ! {catalog_query_response,
                            {Partition, Index, Field, Term, JSONProps},
                            OutputRef},
            receive_catalog_query_results(StreamRef, OutputPid, OutputRef);
        Msg ->
            io:format("receive_catalog_query_results: unknown message: ~p~n", [Msg]),
            receive_catalog_query_results(StreamRef, OutputPid, OutputRef)
    end,
    ok.

%% @spec get(state(), BKey :: riak_object:bkey()) ->
%%         {ok, Val :: binary()} | {error, Reason :: term()}
%% @doc Get the object stored at the given bucket/key pair. The merge
%% backend does not support key-based lookups, so always return
%% {error, notfound}.
get(_State, _BKey) ->
    {error, notfound}.

is_empty(State) ->
    io:format("is_empty(~p)~n", [State]),
    Partition = list_to_binary(integer_to_list(State#state.partition)),
    handle_command(no_state, {command,
                              <<"partition_count">>,
                              Partition,
                              <<"">>,
                              <<"">>}) == "0".

drop(State) ->
    io:format("drop(~p)~n", [State]),
    Partition = list_to_binary(integer_to_list(State#state.partition)),
    handle_command(no_state, {command,
                              <<"drop_partition">>,
                              Partition,
                              <<"">>,
                              <<"">>}),
    ok.

%% @spec delete(state(), BKey :: riak_object:bkey()) ->
%%          ok | {error, Reason :: term()}
%% @doc Writes are not supported.
delete(_State, _BKey) ->
    {error, not_supported}.

%% @spec list(state()) -> [{Bucket :: riak_object:bucket(),
%%                          Key :: riak_object:key()}]
%% @doc Get a list of all bucket/key pairs stored by this backend
list(_State) ->
    io:format("list(~p)~n", [_State]),
    throw({error, not_supported}).

%% @spec list_bucket(state(), riak_object:bucket()) ->
%%           [riak_object:key()]
%% @doc Get a list of the keys in a bucket
list_bucket(_State, _Bucket) ->
    io:format("list_bucket(~p, ~p)~n", [_State, _Bucket]),
    throw({error, not_supported}).

%% spawn a process to kick off the catalog listing
%%   for the this partition, e.g.,
fold(State, Fun0, Acc) ->
    io:format("fold(~p, ~p, ~p)~n", [State, Fun0, Acc]),
    io:format("fold/sync...~n"),
    sync(),
    io:format("fold/sync complete.~n"),
    Partition = integer_to_list(State#state.partition),
    {ok, Conn} = raptor_conn_sup:new_conn(),
    Me = self(),
    CatalogResultsPid = spawn_link(fun() ->
        fold_catalog_process(Me, Fun0, Acc, false, 0, 0, false) end),
    spawn_link(fun() ->
        {ok, StreamRef} = raptor_conn:catalog_query(
            Conn,
            ["partition_id:\"", Partition , "\""]),
        receive_catalog_query_results(StreamRef, CatalogResultsPid, erlang:make_ref()),
        raptor_conn:close(Conn) end),
    receive_fold_results(Acc, 0).

%% receive catalog entries for current partition & kick
%%   off a stream process for each one in parallel
fold_catalog_process(FoldResultPid,
                     Fun0, Acc,
                     CatalogDone,
                     StreamProcessCount,
                     FinishedStreamProcessCount,
                     DeferredTables) ->
    %% kick off one fold_stream_process per catalog entry that comes back
    %%   increment StreamProcessCount
    %% when receive done from fold_stream_process processes, increment
    %%   FinishedStreamProcessCount
    %% when CatalogDone = true && StreamProcessCount == FinishedStreamProcessCount,
    %%   exit
    Me = self(),
    receive
        {catalog_query_response, done, _OutputRef} ->
            case StreamProcessCount of
                0 ->
                    FoldResultPid ! {fold_result, done},
                    true;
                _SPC ->
                    fold_catalog_process(FoldResultPid, Fun0, Acc, true,
                        StreamProcessCount, FinishedStreamProcessCount, DeferredTables)
            end;

        {catalog_query_response, {Partition, Index, Field, Term, JSONProps}, _OutputRef} ->
            %% kick off stream for this PIFT
            case (StreamProcessCount - FinishedStreamProcessCount) >
                  ?MAX_HANDOFF_STREAMS of
                true ->
                    %io:format("fold_catalog_process: deferring ~p.~p.~p~n",
                    %    [Index, Field, Term]),
                    self() ! {catalog_query_response,
                              {Partition, Index, Field, Term, JSONProps}, _OutputRef},
                    fold_catalog_process(FoldResultPid, Fun0, Acc, CatalogDone,
                                         StreamProcessCount, FinishedStreamProcessCount, true);
                false ->
                    spawn_link(fun() ->
                        io:format("fold_catalog_process: catalog_query_response: ~p: ~p.~p.~p (~p)~n",
                            [Partition, Index, Field, Term, JSONProps]),
                        {ok, Conn} = raptor_conn_sup:new_conn(),
                        {ok, StreamRef} = raptor_conn:stream(
                            Conn,
                            list_to_binary(Index),
                            list_to_binary(Field),
                            list_to_binary(Term),
                            <<"0">>, <<"0">>, <<"0">>, %% todo: sub type, startterm, endterm (tbd)
                            list_to_binary(Partition)),
                        fold_stream_process(Me, FoldResultPid, StreamRef, Fun0, Acc, Index, Field, Term),
                        raptor_conn:close(Conn) end),
                    fold_catalog_process(FoldResultPid, Fun0, Acc, CatalogDone,
                                         StreamProcessCount+1, FinishedStreamProcessCount, false)
                end;

        {fold_stream, done, _StreamRef1} ->
            %%io:format("fold_stream: done: ~p of ~p~n",
            %%    [FinishedStreamProcessCount, StreamProcessCount]),
            case FinishedStreamProcessCount >= (StreamProcessCount-1) andalso
                 CatalogDone == true andalso
                 DeferredTables == false of
                    true ->
                        io:format("fold_catalog_process: streaming complete (~p of ~p)~n",
                            [(FinishedStreamProcessCount+1), StreamProcessCount]),
                        FoldResultPid ! {fold_result, done};
                    false ->
                        fold_catalog_process(FoldResultPid, Fun0, Acc, CatalogDone,
                            StreamProcessCount, FinishedStreamProcessCount+1, false)
                end;
        Msg ->
            io:format("fold_catalog_process: unknown message: ~p~n", [Msg]),
            fold_catalog_process(FoldResultPid, Fun0, Acc, CatalogDone,
                StreamProcessCount, FinishedStreamProcessCount, DeferredTables)
        after ?FOLD_TIMEOUT ->
            case FinishedStreamProcessCount >= (StreamProcessCount) of
                true -> ok;
                false ->
                    io:format("fold_catalog_process: timed out (~p of ~p), proceeding to {fold_result, done}~n",
                        [FinishedStreamProcessCount, StreamProcessCount])
            end,
            FoldResultPid ! {fold_result, done}
    end.

%% for each result of a stream process, package the entry in the
%%   form of an infamously shady put-embedded command and forward
%%   to receive_fold_results process
fold_stream_process(CatalogProcessPid, FoldResultPid, StreamRef, Fun0, Acc, Index, Field, Term) ->
    receive
        {stream, StreamRef, "$end_of_table", _} ->
            CatalogProcessPid ! {fold_stream, done, StreamRef},
            io:format("fold_stream_process: table complete: ~p.~p.~p~n",
                [Index, Field, Term]);
        {stream, StreamRef, Value, Props} ->
            Props2 = binary_to_term(Props),
            IndexBin = riak_search_utils:to_binary(Index),
            FieldTermBin = riak_search_utils:to_binary([Field, ".", Term]),
            Payload = {index, Index, Field, Term, Value, Props2, erlang:now()},
            BObj = term_to_binary(riak_object:new(IndexBin, FieldTermBin, Payload)),
            FoldResultPid ! {fold_result, Fun0({IndexBin, FieldTermBin}, BObj, Acc)},
            fold_stream_process(CatalogProcessPid, FoldResultPid, StreamRef, Fun0, Acc, Index, Field, Term);
        Msg ->
            io:format("fold_stream_process: unknown message: ~p~n", [Msg]),
            fold_stream_process(CatalogProcessPid, FoldResultPid, StreamRef, Fun0, Acc, Index, Field, Term)
        after ?FOLD_TIMEOUT ->
            CatalogProcessPid ! {fold_stream, done, StreamRef},
            io:format("fold_stream_process: table timed out: ~p.~p.~p~n",
                [Index, Field, Term])
    end.

%% receive the Fun0(processed) objects from all the "buckets" on this partition, accumulate them
%%   and return them
receive_fold_results(Acc, Count) ->
    receive
        {fold_result, done} ->
            io:format("receive_fold_results: fold complete [~p objects].~n",
                [Count]),
            Acc;
        {fold_result, _Obj} ->
            receive_fold_results(Acc, Count+1)
    end.

%%%



poke(Command) ->
    handle_command(no_state, {command, Command, <<"">>, <<"">>, <<"">>}).

sync() ->
    poke("sync").

toggle_raptor_debug() ->
    poke("toggle_debug").

shutdown_raptor() ->
    io:format("issuing raptor engine shutdown~n"),
    poke("shutdown").

raptor_status() ->
    Status = string:tokens(poke("status"), "`"),
    io:format("~p~n", [Status]),
    Status.

%% test fold
test_fold() ->
    Fun0 = fun(_BKey, _Obj, Acc) ->
        Acc
    end,
    State = #state { partition=0, conn=undefined },
    spawn(fun() ->
        fold(State, Fun0, []) end).

test_is_empty() ->
    State = #state { partition=0, conn=undefined },
    is_empty(State).

test_drop() ->
    State = #state { partition=0, conn=undefined },
    drop(State).
