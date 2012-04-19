%% ----------------------------------------------------------------------------
%%
%% lsm_btree: LSM-trees (Log-Structured Merge Trees) Indexed Storage
%%
%% Copyright 2011-2012 (c) Trifork A/S.  All Rights Reserved.
%% http://trifork.com/ info@trifork.com
%%
%% Copyright 2012 (c) Basho Technologies, Inc.  All Rights Reserved.
%% http://basho.com/ info@basho.com
%%
%% This file is provided to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
%% License for the specific language governing permissions and limitations
%% under the License.
%%
%% ----------------------------------------------------------------------------

-module(lsm_btree_merger).
-author('Kresten Krab Thorup <krab@trifork.com>').

%%
%% Merging two BTrees
%%

-export([merge/5]).

-include("lsm_btree.hrl").

%%
%% Most likely, there will be plenty of I/O being generated by
%% concurrent merges, so we default to running the entire merge
%% in one process.
%%
-define(LOCAL_WRITER, true).

merge(A,B,C, Size, IsLastLevel) ->
    {ok, BT1} = lsm_btree_reader:open(A, sequential),
    {ok, BT2} = lsm_btree_reader:open(B, sequential),
    case ?LOCAL_WRITER of
        true ->
            {ok, Out} = lsm_btree_writer:init([C, Size]);
        false ->
            {ok, Out} = lsm_btree_writer:open(C, Size)
    end,

    {node, AKVs} = lsm_btree_reader:first_node(BT1),
    {node, BKVs} = lsm_btree_reader:first_node(BT2),

    {ok, Count, Out2} = scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, 0, {0, none}),

    %% finish stream tree
    ok = lsm_btree_reader:close(BT1),
    ok = lsm_btree_reader:close(BT2),

    case ?LOCAL_WRITER of
        true ->
            {stop, normal, ok, _} = lsm_btree_writer:handle_call(close, self(), Out2);
        false ->
            ok = lsm_btree_writer:close(Out2)
    end,

    {ok, Count}.

step({N, From}) ->
    {N-1, From}.

scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, {0, FromPID}) ->
    case FromPID of
        none ->
            ok;
        {PID, Ref} ->
            PID ! {Ref, step_done}
    end,

%    error_logger:info_msg("waiting for step in ~p~n", [self()]),

    receive
        {step, From, HowMany} ->
%            error_logger:info_msg("got step ~p,~p in ~p~n", [From,HowMany, self()]),
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, {HowMany, From})
    end;

scan(BT1, BT2, Out, IsLastLevel, [], BKVs, Count, Step) ->
    case lsm_btree_reader:next_node(BT1) of
        {node, AKVs} ->
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, Step);
        end_of_data ->
            scan_only(BT2, Out, IsLastLevel, BKVs, Count, Step)
    end;

scan(BT1, BT2, Out, IsLastLevel, AKVs, [], Count, Step) ->
    case lsm_btree_reader:next_node(BT2) of
        {node, BKVs} ->
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, Step);
        end_of_data ->
            scan_only(BT1, Out, IsLastLevel, AKVs, Count, Step)
    end;

scan(BT1, BT2, Out, IsLastLevel, [{Key1,Value1}|AT]=AKVs, [{Key2,Value2}|BT]=BKVs, Count, Step) ->
    if Key1 < Key2 ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = lsm_btree_writer:handle_cast({add, Key1, Value1}, Out);
                false ->
                    ok = lsm_btree_writer:add(Out2=Out, Key1, Value1)
            end,

            scan(BT1, BT2, Out2, IsLastLevel, AT, BKVs, Count+1, step(Step));

       Key2 < Key1 ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = lsm_btree_writer:handle_cast({add, Key2, Value2}, Out);
                false ->
                    ok = lsm_btree_writer:add(Out2=Out, Key2, Value2)
            end,
            scan(BT1, BT2, Out2, IsLastLevel, AKVs, BT, Count+1, step(Step));

       (?TOMBSTONE =:= Value2) and (true =:= IsLastLevel) ->
            scan(BT1, BT2, Out, IsLastLevel, AT, BT, Count, step(Step));

       true ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = lsm_btree_writer:handle_cast({add, Key2, Value2}, Out);
                false ->
                    ok = lsm_btree_writer:add(Out2=Out, Key2, Value2)
            end,
            scan(BT1, BT2, Out2, IsLastLevel, AT, BT, Count+1, step(Step))
    end.

scan_only(BT, Out, IsLastLevel, [], Count, Step) ->
    case lsm_btree_reader:next_node(BT) of
        {node, KVs} ->
            scan_only(BT, Out, IsLastLevel, KVs, Count, step(Step));
        end_of_data ->
            {ok, Count, Out}
    end;

scan_only(BT, Out, true, [{_,?TOMBSTONE}|Rest], Count, Step) ->
    scan_only(BT, Out, true, Rest, Count, step(Step));

scan_only(BT, Out, IsLastLevel, [{Key,Value}|Rest], Count, Step) ->
    case ?LOCAL_WRITER of
        true ->
            {noreply, Out2} = lsm_btree_writer:handle_cast({add, Key, Value}, Out);
        false ->
            ok = lsm_btree_writer:add(Out2=Out, Key, Value)
    end,
    scan_only(BT, Out2, IsLastLevel, Rest, Count+1, step(Step)).
