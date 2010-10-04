%%%---------------------------------------------------------------------------------------
%%% @author     Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @author     Benjamin Black <b@b3k.us>
%%% @copyright  2007 Roberto Saccon, Tait Larson
%%% @copyright  2010 Benjamin Black
%%% @doc        ETS-based state tracker
%%% @reference  See <a href="http://erlyvideo.googlecode.com" target="_top">http://erlyvideo.googlecode.com</a> for more information
%%% @end
%%%
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
%%%---------------------------------------------------------------------------------------
-module(erlycomet_ets_store).
-author('rsaccon@gmail.com').
-author('telarson@gmail.com').
-author('b@b3k.us').

-behaviour(gen_server).

-include_lib("include/erlycomet.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/0, init/1, ping/1, handle_info/2, handle_call/3, handle_cast/2]).
-export([stop/0, terminate/2, code_change/3]).

start_link() ->
	gen_server:start_link({local, erlycomet_store}, ?MODULE, [], []).

init(_) ->
	init_db(),
	{ok, []}.

ping(S) -> {pong, S}.
handle_info(_, S) -> {noreply, S}.
handle_cast(_, S) -> {noreply, S}.

handle_call({add_connection, ClientId, Pid}, _, S) ->
  Res = add_connection(ClientId, Pid),
  {reply, Res, S};
handle_call({replace_connection, ClientId, Pid, State}, _, S) ->
  Res = replace_connection(ClientId, Pid, State),
  {reply, Res, S};
handle_call({connections}, _, S) ->
  Res = connections(),
  {reply, Res, S};
handle_call({connection, ClientId}, _, S) ->
  Res = connection(ClientId),
  {reply, Res, S};
handle_call({connection_pid, ClientId}, _, S) ->
  Res = connection_pid(ClientId),
  {reply, Res, S};
handle_call({remove_connection, ClientId}, _, S) ->
  Res = remove_connection(ClientId),
  {reply, Res, S};
handle_call({subscribe, ClientId, ChannelName}, _, S) ->
  Res = subscribe(ClientId, ChannelName),
  {reply, Res, S};
handle_call({unsubscribe, ClientId, ChannelName}, _, S) ->
  Res = unsubscribe(ClientId, ChannelName),
  {reply, Res, S};
handle_call({channels}, _, S) ->
  Res = channels(),
  {reply, Res, S};
handle_call({subscriber_pids, Channel}, _, S) ->
  Res = subscriber_pids(Channel),
  {reply, Res, S}.

stop() -> ok.
terminate(_Reason, _) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%%
%% Initialization
%%
ets_tables() ->
  [{connection,
    [set, protected, named_table, {heir, self(), []},
	   {write_concurrency, false}]},
   {channel,
    [bag, protected, named_table, {heir, self(), []},
	   {write_concurrency, false}]}].

init_db() ->
  [create_table(Name, Args) || {Name, Args} <- ets_tables()].

create_table(Name, Args) ->
  case ets:info(Name) of
		undefined -> ets:new(Name, Args);
		_ -> ok
	end.

%%====================================================================
%% API
%%====================================================================
%%-------------------------------------------------------------------------
%% @spec (string(), pid()) -> ok | error 
%% @doc
%% adds a connection
%% @end
%%-------------------------------------------------------------------------
add_connection(ClientId, Pid) ->
  add_connection(ClientId, Pid, undefined).

add_connection(ClientId, Pid, State) ->
  Conn = #connection{client_id=ClientId, pid=Pid, state=State},
	case ets:insert(connection, {ClientId, Conn}) of
	  true -> ok;
    _ -> {error, "Database failure"}
  end.	

%%-------------------------------------------------------------------------
%% @spec (string(), pid(), atom()) -> {ok, new} | {ok, replaced} | error 
%% @doc
%% replaces a connection
%% @end
%%-------------------------------------------------------------------------
replace_connection(ClientId, Pid, NewState) ->
  case connection(ClientId) of
    undefined ->
      {add_connection(ClientId, Pid, NewState), created};
    #connection{state=State} ->
      Res = case State of
        handshake -> replaced_hs;
        _ -> replaced
      end,
      {add_connection(ClientId, Pid, NewState), Res};
    _ ->
      {error, "Database failure"}
  end.
       
          
%%--------------------------------------------------------------------
%% @spec () -> list()
%% @doc
%% returns list of connections
%% @end 
%%--------------------------------------------------------------------    
connections() -> 
  qlc:e(qlc:q([X || X <- ets:table(connection)])).
  
connection(ClientId) ->
  case ets:lookup(connection, ClientId) of
	  [] -> undefined;
	  [{ClientId, Conn}] -> Conn;
	  _ -> {error, "Database failure"}
  end.


%%--------------------------------------------------------------------
%% @spec (string()) -> pid()
%% @doc 
%% returns the PID of a connection if it exists
%% @end 
%%--------------------------------------------------------------------    
connection_pid(ClientId) ->
  case connection(ClientId) of
    undefined -> undefined;
    #connection{pid=Pid} -> Pid
  end.    

%%--------------------------------------------------------------------
%% @spec (string()) -> ok | error  
%% @doc
%% removes a connection
%% @end 
%%--------------------------------------------------------------------  
remove_connection(ClientId) ->
  %% Need to also delete all channel entries for this client
  % {{'$1', ClientId}}
  % qlc:e(qlc:q([X || X <- ets:table(channel)])).

  case ets:delete(connection, ClientId) of
    true -> ok;
    _ -> {error, "Database failure"}
  end.


%%--------------------------------------------------------------------
%% @spec (string(), string()) -> ok | error 
%% @doc
%% subscribes a client to a channel
%% @end 
%%--------------------------------------------------------------------
subscribe(ClientId, ChannelName) ->
  case subscribed(ClientId, ChannelName) of
    true -> {error, "Duplicate subscription"};
    false ->
      case ets:insert(channel, {ChannelName, ClientId}) of
        true -> ok;
        _ -> {error, "Database failure"}
      end
  end.

subscribed(ClientId, ChannelName) ->
  case ets:lookup(channel, ChannelName) of
    [] -> false; % or {error, channel_not_found} ?
    Ids -> lists:member(ClientId, Ids)
  end.

    
%%--------------------------------------------------------------------
%% @spec (string(), string()) -> ok | error  
%% @doc
%% unsubscribes a client from a channel
%% @end 
%%--------------------------------------------------------------------
unsubscribe(ClientId, ChannelName) ->
  case ets:delete_object(channel, {ChannelName, ClientId}) of
    true -> ok;
    _ -> {error, "Database failure"}
  end.


%%--------------------------------------------------------------------
%% @spec () -> list()
%% @doc
%% returns a list of channels
%% @end 
%%--------------------------------------------------------------------
channels() ->
  proplists:get_keys(qlc:e(qlc:q([X || X <- ets:table(channel)]))).


%%--------------------------------------------------------------------
%% @spec (string()) -> list() 
%% @doc
%% returns a list of client pids for a channel
%% @end 
%%--------------------------------------------------------------------
subscriber_pids(Channel) ->
  case ets:lookup(channel, Channel) of
    [] -> [];
    Subscribers ->
      [connection_pid(ClientId) || {_, ClientId} <- Subscribers]
  end.
