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

-module(riak_reduce_phase_fsm).
-behaviour(gen_fsm).

-export([start_link/4]).
-export([init/1, handle_event/3, handle_sync_event/4,
         handle_info/3, terminate/3, code_change/4]).

-export([wait/2]). 

-record(state, {done,qterm,next_fsm,coord,acc,reduced}).

start_link(_Ring,QTerm,NextFSM,Coordinator) ->
    gen_fsm:start_link(?MODULE, [QTerm,NextFSM,Coordinator], []).
%% @private
init([QTerm,NextFSM,Coordinator]) ->
    {_,_,_,Acc} = QTerm,
    riak_eventer:notify(riak_reduce_phase_fsm, reduce_start, start),
    {ok,wait,#state{done=false,qterm=QTerm,next_fsm=NextFSM,
                    coord=Coordinator,acc=Acc,reduced=[]}}.

wait(done, StateData=#state{acc=Acc,next_fsm=NextFSM,coord=Coord,
                            reduced=Reduced}) ->
    case NextFSM of
        final -> nop;
        _ -> 
            gen_fsm:send_event(NextFSM, {input, Reduced}),
            gen_fsm:send_event(NextFSM, done)
    end,
    case Acc of
        false -> nop;
        true -> gen_fsm:send_event(Coord, {acc, {list, Reduced}})
    end,
    gen_fsm:send_event(Coord, {done, self()}),
    riak_eventer:notify(riak_reduce_phase_fsm, done, self()),
    {stop,normal,StateData};
wait({input,Inputs}, StateData=#state{next_fsm=NextFSM,
                                      qterm={reduce,FunTerm,Arg,_Acc},
                                      coord=Coord,reduced=Reduced}) ->
    NewInputs = Inputs ++ Reduced,
    try
        NewReduced = case FunTerm of
            {qfun,F} -> F(NewInputs,Arg);
            {modfun,M,F} -> M:F(NewInputs,Arg)
        end,
        {next_state, wait, StateData#state{reduced=NewReduced}}
    catch C:R ->
         Reason = {C, R, erlang:get_stacktrace()},
         case NextFSM of
             final -> nop;
             _ -> gen_fsm:send_event(NextFSM, die)
         end,
         gen_fsm:send_event(Coord, {error, self(), Reason}),
         {stop,normal,StateData}
    end;
wait(die, StateData=#state{next_fsm=NextFSM}) ->
    riak_eventer:notify(riak_reduce_phase_fsm, die, die),
    case NextFSM of
        final -> nop;
        _ -> gen_fsm:send_event(NextFSM, die)
    end,
    {stop,normal,StateData}.

%% @private
handle_event(_Event, _StateName, StateData) -> {stop,badmsg,StateData}.
%% @private
handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.
%% @private
handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.
%% @private
terminate(Reason, _StateName, _State) ->
    riak_eventer:notify(riak_reduce_phase_fsm, phase_end, Reason),
    Reason.
%% @private
code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

