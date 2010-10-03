%%%-------------------------------------------------------------------
%%% @author Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @author Tait Larson
%%% @author Benjamin Black <b@b3k.us>
%%% @copyright 2007 Roberto Saccon, Tait Larson
%%% @copyright 2010 Benjamin Black
%%% @doc 
%%% Comet extension for MochiWeb
%%% @end  
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2007 Roberto Saccon, Tait Larson
%%% Copyright (c) 2010 Benjamin Black
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%% @since 2007-11-11 by Roberto Saccon, Tait Larson
%%%-------------------------------------------------------------------
-module(erlycomet_request, [CustomAppModule]).
-author('telarson@gmail.com').
-author('rsaccon@gmail.com').
-author('b@b3k.us').


%% API
-export([handle/1]).

-include_lib("include/erlycomet.hrl").

-define(accuracy_target, 25).

-record(timesync, {
    ts = 0,
    tc = 0,
    l = 0,
    o = 0}).

-record(state, {
    id = undefined,
    connection_type,
    timesync = #timesync{},
    events = [],
    timeout = 1200000,      %% 20 min, just for testing
    callback = undefined}).  


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec
%% @doc handle POST / GET Comet messages
%% @end 
%%--------------------------------------------------------------------
handle(Req) ->
    handle(Req, Req:get(method)).
    
-record(parsed_req, {message, jsonp}).

%% Extract args from the message in an order-independent way
parse_args(Args) -> parse_args(Args, #parsed_req{}).

parse_args([{"message", Msg} | Rest], Acc) ->
  parse_args(Rest, Acc#parsed_req{message = Msg});
parse_args([{"jsonp", Val} | Rest], Acc) ->
  parse_args(Rest, Acc#parsed_req{jsonp = Val});
parse_args([{"callback", Val} | Rest], Acc) ->
  parse_args(Rest, Acc#parsed_req{jsonp = Val});
parse_args([_Other | Rest], Acc) ->
  parse_args(Rest, Acc);
parse_args([], Acc) -> Acc.

handle(Req, 'POST') ->
  handle(Req, parse_args(Req:parse_post()));
handle(Req, 'GET') ->
  handle(Req, parse_args(Req:parse_qs()));
handle(Req, #parsed_req{message = Msg, jsonp = Callback})
  when Msg =/= undefined, Callback =/= undefined ->
    case process_bayeux_msg(Req, json_decode(Msg), Callback) of
      done -> ok;
      [done] -> ok;
      Body ->
        ?LOG_INFO_FORMAT("~p:handle/2 parsed_req | ~p~n", [?MODULE, Body]),
        Resp = callback_wrapper(json_encode(Body), Callback),       
        Req:ok({"text/javascript;charset=UTF-8", Resp})   
    end;       
handle(Req, #parsed_req{message = Msg})
  when Msg =/= undefined ->
    case process_bayeux_msg(Req, json_decode(Msg), undefined) of
      done -> ok;
      [done] -> ok;
      Body -> Req:ok({"text/json", json_encode(Body)})
    end;        
handle(Req, _Parsed) ->
  ?LOG_INFO_FORMAT("Not found for parsed: ~p~n", [_Parsed]),
  Req:not_found().


%%====================================================================
%% Internal functions
%%====================================================================

process_bayeux_msg(Req, JsonObj, Callback) when is_list(JsonObj) ->
  [ process_msg(Req, X, Callback) || X <- JsonObj ];
process_bayeux_msg(Req, JsonObj, Callback) ->
  process_msg(Req, JsonObj, Callback).


process_msg(Req, Struct, Callback) ->
  process_cmd(Req, get_json_map_val(<<"channel">>, Struct), Struct, Callback).


get_json_map_val(Key, {struct, Pairs}) when is_list(Pairs) ->
  case [ V || {K, V} <- Pairs, K =:= Key] of
    [] -> undefined;
    [ V | _Rest ] -> V
  end;
get_json_map_val(_, _) ->
  undefined.
    

process_cmd(_Req, <<"/meta/handshake">> = Channel, Struct, _) ->  
  % Advice = {struct, [{reconnect, "retry"},
  %                   {interval, 5000}]},
  % - get the alert from 
  {struct, Ext} = get_json_map_val(<<"ext">>, Struct),
  TSyncReq = timesync_req(proplists:get_value(<<"timesync">>, Ext)),
  
  Id = generate_id(),
  erlycomet_api:replace_connection(Id, 0, handshake),
  {struct, [
    {channel, Channel}, 
    {version, 1.0},
    {supportedConnectionTypes, [
        <<"long-polling">>,
        <<"callback-polling">>]},
    {clientId, Id},
    timesync_ext(TSyncReq),
    {successful, true}]};
    
process_cmd(Req, <<"/meta/connect">> = Channel, Struct, Callback) ->  
  ClientId = get_json_map_val(<<"clientId">>, Struct),
  ConnectionType = get_json_map_val(<<"connectionType">>, Struct),
  {struct, Ext} = get_json_map_val(<<"ext">>, Struct),
  TSyncReq = timesync_req(proplists:get_value(<<"timesync">>, Ext)),
  
  L = [{channel,  Channel}, {clientId, ClientId}],    
  case erlycomet_api:replace_connection(ClientId, self(), connected) of
    {ok, Status} when Status =:= ok ; Status =:= replaced_hs ->
      {struct,
        lists:flatten([
          [timesync_ext(TSyncReq)],
          [{successful, true}],
          L])};
    % don't reply immediately to new connect message.
    % instead wait. when new message is received, reply to connect and 
    % include the new message.  This is acceptable given bayeux spec. see section 4.2.2
    {ok, replaced} ->   
      Msg  = {struct, [{successful, true} | L]},
      Resp = Req:respond({200, [], chunked}),
      loop(Resp, #state{id = ClientId, 
          connection_type = ConnectionType,
          timesync = TSyncReq,
          events = [Msg],
          callback = Callback});
    _ ->
      {struct,
        lists:flatten([
          [timesync_ext(TSyncReq)],
          [{successful, false}],
          L])}
  end;    
           
process_cmd(Req, <<"/meta/disconnect">> = Channel, Struct, _) ->  
  ClientId = get_json_map_val(<<"clientId">>, Struct),
  process_cmd1(Req, Channel, ClientId);
    
process_cmd(Req, <<"/meta/subscribe">> = Channel, Struct, _) ->   
  ClientId = get_json_map_val(<<"clientId">>, Struct),
  Subscription = get_json_map_val(<<"subscription">>, Struct),
  process_cmd1(Req, Channel, ClientId, Subscription);
    
process_cmd(Req, <<"/meta/unsubscribe">> = Channel, Struct, _) -> 
  ClientId = get_json_map_val(<<"clientId">>, Struct),
  Subscription = get_json_map_val(<<"subscription">>, Struct),
  process_cmd1(Req, Channel, ClientId, Subscription);   
          
process_cmd(Req, Channel, Struct, _) ->
  ClientId = get_json_map_val(<<"clientId">>, Struct),
  Data = get_json_map_val(<<"data">>, Struct),
  process_cmd1(Req, Channel, ClientId, rpc(Data, Channel)).   
    
    
process_cmd1(_, Channel, undefined) ->
  {struct, [{<<"channel">>, Channel}, {successful, false}]};       
process_cmd1(Req, Channel, Id) ->
  process_cmd2(Req, Channel, Id).

process_cmd1(_, Channel, undefined, _) ->   
  {struct, [{<<"channel">>, Channel}, {successful, false}]};  
process_cmd1(Req, Channel, Id, Data) ->
  process_cmd2(Req, Channel, Id, Data).
       
        
process_cmd2(_, <<"/meta/disconnect">> = Channel, ClientId) -> 
  L = [{channel, Channel}, {clientId, ClientId}],
  case erlycomet_api:remove_connection(ClientId) of
    ok -> {struct, [{successful, true}  | L]};
    _ ->  {struct, [{successful, false}  | L]}
  end. 
    
                     
process_cmd2(_, <<"/meta/subscribe">> = Channel, ClientId, Subscription) ->    
  L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],
  case erlycomet_api:subscribe(ClientId, Subscription) of
    ok -> {struct, [{successful, true}  | L]};
    _ ->  {struct, [{successful, false}  | L]}
  end;  
         
process_cmd2(_, <<"/meta/unsubscribe">> = Channel, ClientId, Subscription) ->  
  L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],          
  case erlycomet_api:unsubscribe(ClientId, Subscription) of
    ok -> {struct, [{successful, true}  | L]};
    _ ->  {struct, [{successful, false}  | L]}
  end;  
    
process_cmd2(_, <<$/, $s, $e, $r, $v, $i, $c, $e, $/, _/binary>> = Channel, ClientId, Data) ->  
  L = [{"channel", Channel}, {"clientId", ClientId}],
  case erlycomet_api:deliver_to_connection(ClientId, Channel, Data) of
    ok -> {struct, [{"successful", true}  | L]};
    _ ->  {struct, [{"successful", false}  | L]}
  end;   
             
process_cmd2(_, Channel, ClientId, Data) ->  
  case authenticate_channel_write(ClientId, Channel) of
    allow -> try_deliver_channel(Channel, ClientId, Data);
    _ -> result_struct(Channel, ClientId, false)
  end.

authenticate_channel_write(ClientId, Channel) ->
  case catch CustomAppModule:authenticate_channel_write(ClientId, Channel) of
    allow -> allow;
    deny ->  deny;
    {'EXIT', {undef, [{CustomAppModule, authenticate_channel_write, _} | _]}} ->
             allow % default allow to maintain past behavior
  end.

try_deliver_channel(Channel, ClientId, Data) ->
  case erlycomet_api:deliver_to_channel(Channel, Data) of
    ok -> result_struct(Channel, ClientId, true);
    _ ->  result_struct(Channel, ClientId, false)
  end.

result_struct(Channel, ClientId, Result) when is_boolean(Result) ->
  L = [{channel, Channel}, {clientId, ClientId}],
  {struct, [{successful, Result}  | L]}.

json_decode(Str) ->
  mochijson2:decode(Str).
    
json_encode(Body) ->
  ?LOG_INFO_FORMAT("~p:json_encode | ~p~n", [?MODULE, Body]),
  mochijson2:encode(Body).


callback_wrapper(Data, undefined) ->
  Data;       
callback_wrapper(Data, Callback) ->
  lists:concat([Callback, "(", Data, ");"]).
     
                
generate_id() ->
  <<Num:128>> = crypto:rand_bytes(16),
  [HexStr] = io_lib:fwrite("~.16B",[Num]),
  case erlycomet_api:connection_pid(HexStr) of
    undefined -> HexStr;
    _ -> generate_id()
  end.


loop(Resp, #state{events=Events, id=Id,
                  timesync=TSyncReq, callback=Callback} = State) ->
  receive
    stop ->  
      disconnect(Resp, Id, State);
    {add, Event} -> 
      loop(Resp, State#state{events=[Event | Events]});      
    {flush, Event} ->
      Event1 = [timesync_ext(TSyncReq) | Event],
      Events2 = [Event1 | Events],
      send(Resp, events_to_json_struct(Events2, Id), Callback),
      done;                
    flush ->
      [Event | Events2] = Events,
      Event1 = [timesync_ext(TSyncReq) | Event],
      Events3 = [Event1 | Events2],
      send(Resp, events_to_json_struct(Events3, Id), Callback),
      done 
  after State#state.timeout ->
    disconnect(Resp, Id, Callback)
  end.


events_to_json_struct(Events, _Id) ->
  lists:reverse(Events).
  
    
send(Resp, Data, Callback) ->
  Chunk = callback_wrapper(json_encode(Data), Callback),
  Resp:write_chunk(Chunk),
  Resp:write_chunk([]).
    
    
disconnect(Resp, Id, Callback) ->
  erlycomet_api:remove_connection(Id),
  Msg = {struct, [{channel, <<"/meta/disconnect">>}, {successful, true}, {clientId, Id}]},
  Chunk = callback_wrapper(json_encode(Msg), Callback),
  Resp:write_chunk(Chunk),
  Resp:write_chunk([]),
  done.
    
    
rpc({struct, [{<<"id">>, Id}, {<<"method">>, Method}, {<<"params">>, Params}]}, Channel) ->
  Func = list_to_atom(binary_to_list(Method)),
  case catch apply(CustomAppModule, Func, [Channel | Params]) of
    {'EXIT', _} ->
      {struct, [{result, null}, {error, <<"RPC failure">>}, {id, Id}]};
    {error, Reason} ->
      {struct, [{result, null}, {error, Reason}, {id, Id}]};
    Value ->
      {struct, [{result, Value}, {error, null}, {id, Id}]}
  end;
rpc(Msg, _) -> Msg.


%%
% timesync client request
%
% {ext:{timesync:{tc:12345567890,l:23,o:4567},...},...}
%
% tc is the client timestamp in ms since 1970 of when the message was sent
% l is the network lag that the client has calculated
% o is the clock offset that the client has calculated
%
%%
timesync_req(undefined) ->
  #timesync{};
timesync_req({struct, ClientReq}) ->
  TC = proplists:get_value(<<"tc">>, ClientReq, now_in_millis()),
  L = proplists:get_value(<<"l">>, ClientReq, 0),
  O = proplists:get_value(<<"o">>, ClientReq, 0),

  #timesync{ts=now_in_millis(), tc=TC, l=L, o=O}.

%%
%
% timesync server response
%
% {ext:{timesync:{tc:12345567890,ts:1234567900,p:123,a:3},...},...}
%
% tc is the client timestamp of when the message was sent
% ts is the server timestamp of when the message was received
% p is the poll duration in ms - ie the time the server took before sending
%   the response
% a is the measured accuracy of the calculated offset and lag sent by the
%   client
%   -> tc - now - l - o
%
% A Bayeux server that supports timesync should respond only if the measured
% accuracy value is greater than accuracy target.
%%
timesync_res(#timesync{ts=TS, tc=TC, l=L, o=O}) ->
  Now = now_in_millis(),
  P = Now - TS,
  A = TC - Now - L - O,
  case A > ?accuracy_target of
    true -> [];
    false ->
      [{timesync, {struct, [{tc, TC}, {ts, TS}, {p, P}, {a, A}]}}]
  end.

timesync_ext(#timesync{ts=0}) ->
  {ext, {struct, []}};
timesync_ext(TSyncReq) ->
  {ext, {struct, timesync_res(TSyncReq)}}.
  
now_in_millis() ->
  {Mega, Sec, Micro} = now(),
	trunc(((Mega * 1000000) + Sec) * 1000 + (Micro / 1000) + 0.5).
