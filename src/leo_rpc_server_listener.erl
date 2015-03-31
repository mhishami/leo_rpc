%%======================================================================
%%
%% Leo RPC
%%
%% Copyright (c) 2012-2015 Rakuten, Inc.
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
%% @doc leo_rpc_server_listener is a rpc-server's listener
%% @reference https://github.com/leo-project/leo_rpc/blob/master/src/leo_rpc_server_listener.erl
%% @end
%%======================================================================
-module(leo_rpc_server_listener).

-author('Yosuke Hara').

%% External API
-export([start_link/5]).

%% Callbacks
-export([init/5, accept/5]).

-include("leo_rpc.hrl").
-include_lib("eunit/include/eunit.hrl").


%%-----------------------------------------------------------------------
%% External API
%%-----------------------------------------------------------------------
%% @doc Start a rpc-server's listener
-spec(start_link(Id, Socket, State, Module, Options) ->
             {ok, pid()} when Id::{atom(), atom()},
                              Socket::pid(),
                              State::atom(),
                              Module::module(),
                              Options::#tcp_server_params{}).
start_link({Locale, Name}, Socket, State, Module, Options) ->
    {ok, Pid} = proc_lib:start_link(
                  ?MODULE, init,
                  [self(), Socket, State, Module, Options]),

    case Locale of
        local -> register(Name, Pid);
        _ -> global:register_name(Name, Pid)
    end,
    {ok, Pid}.


%% ---------------------------------------------------------------------
%% Callbacks
%% ---------------------------------------------------------------------
%% @doc Callback - Initialize the server
-spec(init(Parent, Socket, State, Module, Options) ->
             ok when Parent::pid(),
                     Socket::gen_tcp:socket(),
                     State::any(),
                     Module::module(),
                     Options::#tcp_server_params{}).
init(Parent, Socket, State, Module, Options) ->
    proc_lib:init_ack(Parent, {ok, self()}),

    ListenerOptions = Options#tcp_server_params.listen,
    Active = proplists:get_value(active, ListenerOptions),
    accept(Socket, State, Module, Active, Options).


%% @doc Callback - Accept the communication
-spec(accept(ListenSocket, State, Module, Active, Options) ->
             ok when ListenSocket::gen_tcp:socket(),
                     State::any(),
                     Module::module(),
                     Active::boolean(),
                     Options::#tcp_server_params{}).
accept(ListenSocket, State, Module, Active,
       #tcp_server_params{accept_timeout = Timeout,
                          accept_error_sleep_time = SleepTime} = Options) ->
    case gen_tcp:accept(ListenSocket, Timeout) of
        {ok, Socket} ->
            case recv(Active, Socket, State, Module, Options) of
                {error, _Reason} ->
                    gen_tcp:close(Socket);
                _ ->
                    void
            end;
        {error, _Reason} ->
            timer:sleep(SleepTime)
    end,
    accept(ListenSocket, State, Module, Active, Options).


%% @private
recv(false = Active, Socket, State, Module, Options) ->
    #tcp_server_params{recv_length  = Length,
                       recv_timeout = Timeout} = Options,
    case catch gen_tcp:recv(Socket, Length, Timeout) of
        {ok, Data} ->
            call(Active, Socket, Data, State, Module, Options);
        {'EXIT', Reason} ->
            {error, Reason};
        {error, closed} ->
            {error, connection_closed};
        {error, Reason} ->
            {error, Reason}
    end;

recv(true = Active, _DummySocket, State, Module, Options) ->
    receive
        {tcp, Socket, Data} ->
            call(Active, Socket, Data, State, Module, Options);
        {tcp_closed, _Socket} ->
            {error, connection_closed};
        {error, Reason} ->
            {error, Reason}
    after Options#tcp_server_params.recv_timeout ->
            {error, timeout}
    end.


%% @private
call(Active, Socket, Data, State, Module, Options) ->
    case Module:handle_call(Socket, Data, State) of
        {reply, DataToSend, NewState} ->
            gen_tcp:send(Socket, DataToSend),
            recv(Active, Socket, NewState, Module, Options);
        {noreply, NewState} ->
            recv(Active, Socket, NewState, Module, Options);
        {close, State} ->
            {error, connection_closed};
        {close, DataToSend, State} ->
            gen_tcp:send(Socket, DataToSend);
        Other ->
            Other
    end.

