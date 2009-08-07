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

-module(riak_vnode_master).

-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
-record(idxrec, {idx, pid, monref}).
-record(state, {idxtab}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @private
init([]) -> {ok, #state{idxtab=ets:new(riak_vnode_idx,[{keypos,2}])}}.

%% @private
handle_cast({start_vnode, Partition}, State) ->
    _Pid = get_vnode(Partition, State),
    {noreply, State};
handle_cast({vnode_map, {Partition,_Node},
             {ClientPid,QTerm,Storekey,KeyData}}, State) ->
    Pid = get_vnode(Partition, State),
    gen_server:cast(Pid, {map, ClientPid, QTerm, Storekey, KeyData}),
    % (obligation done, now the problem of the vnodes)
    {noreply, State};
handle_cast({vnode_put, {Partition,_Node},
             {FSM_pid,Storekey,RObj,ReqID}}, State) ->
    Pid = get_vnode(Partition, State),
    gen_server:cast(Pid, {put, FSM_pid, Storekey, RObj, ReqID}),
    % (obligation done, now the problem of the vnodes)
    {noreply, State};
handle_cast({vnode_get, {Partition,_Node},
             {FSM_pid,Storekey,ReqID}}, State) ->
    Pid = get_vnode(Partition, State),
    gen_server:cast(Pid, {get, FSM_pid, Storekey, ReqID}),
    % (obligation done, now the problem of the vnodes)
    {noreply, State};
handle_cast({vnode_merkle, {RemoteVN,Partition,Merkle}}, State) ->
    Pid = get_vnode(Partition, State),
    gen_server:cast(Pid, {vnode_merkle, {RemoteVN,Merkle}}),
    % (obligation done, now the problem of the vnodes)
    {noreply, State}.


%% @private
handle_call(all_possible_vnodes, _From, State) ->
    {reply, make_all_active(State), State};
handle_call(all_vnodes, _From, State) ->
    {reply, all_vnodes(State), State};
handle_call({vnode_del, {Partition,_Node},
             {Storekey,ReqID}}, From, State) ->
    Pid = get_vnode(Partition, State),
    gen_server:cast(Pid, {delete, From, Storekey, ReqID}),
    % (obligation done, now the problem of the vnodes)
    {noreply, State};
handle_call({vnode_put_binary, {Partition,_Node},
             {Storekey,Val,_ReqID}}, From, State) ->
    Pid = get_vnode(Partition, State),
    spawn(fun() ->
                  Res = gen_server:call(Pid, {put_binary, Storekey, Val}),
                  gen_server:reply(From,Res)
          end),
    {noreply, State}.

%% @private
handle_info({'DOWN', MonRef, process, _P, _I}, State) ->
    delmon(MonRef, State),
    {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) ->  {ok, State}.

%% @private
idx2vnode(Idx, _State=#state{idxtab=T}) ->
    case ets:match(T, {idxrec, Idx, '$1', '_'}) of
        [[VNodePid]] -> VNodePid;
        [] -> no_match
    end.

%% @private
delmon(MonRef, _State=#state{idxtab=T}) ->
    ets:match_delete(T, {idxrec, '_', '_', MonRef}).

%% @private
add_vnode_rec(I,  _State=#state{idxtab=T}) -> ets:insert(T,I).

%% @private
get_vnode(Idx, State) ->
    case idx2vnode(Idx, State) of
        no_match ->
            {ok, Pid} = riak_vnode:start(Idx),
            MonRef = erlang:monitor(process, Pid),
            add_vnode_rec(#idxrec{idx=Idx,pid=Pid,monref=MonRef}, State),
            Pid;
        X -> X
    end.

%% @private
all_vnodes(_State=#state{idxtab=T}) ->
    lists:flatten(ets:match(T, {idxrec, '_', '$1', '_'})).

make_all_active(State) ->
    {ok, Ring} = riak_ring_manager:get_my_ring(),
    [{I,get_vnode(I,State)} || I <- riak_ring:my_indices(Ring)].
