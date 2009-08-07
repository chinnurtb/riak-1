%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at

%%   http://www.apache.org/licenses/LICENSE-2.0

%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.    

%% @doc This tiny server provides a gossip bridge between riak nodes.

-module(riak_connect).

-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
-export([cast/2]).
-record(state, {me}).

%% @private
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @private
init([]) -> {ok, #state{me=node()}}.

%% @private
cast(RemoteNode, Msg) -> gen_server:cast({riak_connect, RemoteNode}, Msg).

%% @private
handle_cast({gossip_ring, Ring}, State) ->
    riak_ring_gossiper ! {gossip_ring, Ring},
    {noreply, State};
handle_cast({set_ring, Ring}, State) ->
    riak_ring_gossiper ! {set_ring, Ring},
    {noreply, State};
handle_cast({get_ring, RemoteNode}, State) ->
    riak_ring_gossiper ! {get_ring, RemoteNode},
    {noreply, State}.

%% @private
handle_info(_Info, State) -> {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) ->  {ok, State}.

%% @private
handle_call(_, _From, State) -> {noreply, State}.

