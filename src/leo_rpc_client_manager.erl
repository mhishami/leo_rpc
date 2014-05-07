%%======================================================================
%%
%% Leo RPC
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
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
%%======================================================================
-module(leo_rpc_client_manager).

-author('Yosuke Hara').

-behaviour(gen_server).

-include("leo_rpc.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/1, stop/0]).
-export([is_exists/2,
         inspect/0, inspect/1,
         status/0, connected_nodes/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
          tref = undefined :: timer:tref(),
          interval = 0 :: pos_integer(),
          active = [] :: list(tuple())
         }).


%% ===================================================================
%% APIs
%% ===================================================================
-spec(start_link(pos_integer()) ->
             {ok, pid()} | {error, term()}).
start_link(Interval) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Interval], []).


stop() ->
    gen_server:call(?MODULE, stop).


is_exists(IP, Port) ->
    gen_server:call(?MODULE, {is_exists, IP, Port}).

inspect() ->
    gen_server:cast(?MODULE, inspect).

inspect(Node) ->
    gen_server:call(?MODULE, {inspect, Node}).

status() ->
    gen_server:call(?MODULE, status).

connected_nodes() ->
    gen_server:call(?MODULE, connected_nodes).


%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Interval]) ->
    {ok, TRef} = defer_inspect(Interval),
    {ok, #state{interval = Interval, tref = TRef}}.


handle_call(stop, _From, State) ->
    {stop, normal, ok, State};


handle_call({is_exists, IP, Port},_From, State) ->
    Ret = is_exists_1(IP, Port),
    {reply, Ret, State};

handle_call({inspect, Node}, _From, State) ->
    Node1 = case is_atom(Node) of
                true  -> atom_to_list(Node);
                false -> Node
            end,
    [Node2|_] = string:tokens(Node1, "@:"),
    Node3 = list_to_atom(Node2),

    {ok, Active, _} = inspect_fun(0, false),
    Ret = case lists:keyfind(Node3, 1, Active) of
              {_,_Host,_Port, NumOfActive,_Workers} when NumOfActive > 0 ->
                  active;
              _ ->
                  inactive
          end,
    {reply, Ret, State};

handle_call(status, _From, #state{active = Active} = State) ->
    {reply, {ok, Active}, State};

handle_call(connected_nodes, _From, #state{active = Active} = State) ->
    Me = leo_rpc:node(),
    ConnectedNodes = lists:foldl(
                       fun(N, Acc) ->
                               case erlang:element(1, N) of
                                   Node when Node /= Me ->
                                       [Node|Acc];
                                   _ ->
                                       Acc
                               end
                       end, [], Active),
    {reply, {ok, lists:sort(ConnectedNodes)}, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(inspect, #state{interval = Interval} = State) ->
    {ok, Active, TRef} = inspect_fun(Interval),
    {noreply, State#state{active = Active, tref = TRef}};

handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info(stop, State) ->
    {stop, shutdown, State};

handle_info(_Info, State) ->
    {stop, {unhandled_message, _Info}, State}.


terminate(_Reason, #state{tref = TRef} = _State) ->
    timer:cancel(TRef),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% Internal Functions
%%====================================================================
%% @doc Inspect rpc-workers's status
%%
-spec(defer_inspect(pos_integer()) ->
             ok).
defer_inspect(Interval) ->
    timer:apply_after(Interval, ?MODULE, inspect, []).


%% @doc Retrieve destinations by ip and port
%%
is_exists_1(IP, Port) ->
    case ets:first(?TBL_RPC_CONN_INFO) of
        '$end_of_table' ->
            false;
        Key ->
            case ets:lookup(?TBL_RPC_CONN_INFO, Key) of
                [{_, #rpc_conn{ip = IP,
                               port = Port}}|_] ->
                    true;
                _ ->
                    is_exists_2(Key, IP, Port)
            end
    end.

is_exists_2(Key, IP, Port) ->
    case ets:next(?TBL_RPC_CONN_INFO, Key) of
        '$end_of_table' ->
            false;
        Key_1 ->
            case ets:lookup(?TBL_RPC_CONN_INFO, Key) of
                [{_, #rpc_conn{ip = IP,
                               port = Port}}|_] ->
                    true;
                _ ->
                    is_exists_2(Key_1, IP, Port)
            end
    end.


%% @doc Inspect rpc-workers's status
%%
-spec(inspect_fun(pos_integer()) ->
             ok).
inspect_fun(Interval) ->
    inspect_fun(Interval, true).

inspect_fun(Interval, IsDefer) ->
    {ok, Active} = inspect_fun_1([]),
    case IsDefer of
        true  ->
            {ok, TRef} = defer_inspect(Interval),
            {ok, Active, TRef};
        false ->
            {ok, Active, undefined}
    end.

inspect_fun_1([] = Acc) ->
    Ret = ets:first(?TBL_RPC_CONN_INFO),
    inspect_fun_2(Ret, Acc).
inspect_fun_1(Acc, Key) ->
    Ret = ets:next(?TBL_RPC_CONN_INFO, Key),
    inspect_fun_2(Ret, Acc).

inspect_fun_2('$end_of_table', Acc) ->
    {ok, lists:reverse(Acc)};
inspect_fun_2(Key, Acc) ->
    [{_, #rpc_conn{host = Host,
                   port = Port,
                   manager_ref = ManagerRef}}|_] = ets:lookup(?TBL_RPC_CONN_INFO, Key),
    {ok, RawStatus} = gen_server:call(ManagerRef, raw_status),
    Status = leo_misc:get_value('worker_pids', RawStatus, []),
    {ok, Active} = inspect_fun_3(Status, 0),
    inspect_fun_1([{Key, Host, Port, Active, length(Status)}|Acc], Key).

inspect_fun_3([], Active) ->
    {ok, Active};
inspect_fun_3([ServerRef|Rest], Active) ->
    case gen_server:call(ServerRef, status) of
        {ok, true} ->
            inspect_fun_3(Rest, Active + 1);
        _ ->
            inspect_fun_3(Rest, Active)
    end.

