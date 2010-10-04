-module(erlycomet_api).
-author('b@b3k.us').

-export([add_connection/2,
         replace_connection/3,
         connections/0,
         connection/1,
         connection_pid/1,
         remove_connection/1,
         subscribe/2,
         unsubscribe/2,
         channels/0,
         deliver_to_connection/3,
         deliver_to_channel/2]).

add_connection(ClientId, Pid) ->
  gen_server:call(erlycomet_db, {add_connection, ClientId, Pid}).
  
replace_connection(ClientId, Pid, State) ->
  gen_server:call(erlycomet_db, {replace_connection, ClientId, Pid, State}).
  
connections() ->
  gen_server:call(erlycomet_db, {connections}).

connection(ClientId) ->
  gen_server:call(erlycomet_db, {connection, ClientId}).

connection_pid(ClientId) ->
  gen_server:call(erlycomet_db, {connection_pid, ClientId}).
  
remove_connection(ClientId)  ->
   gen_server:call(erlycomet_db, {remove_connection, ClientId}).

subscribe(ClientId, ChannelName) ->
  gen_server:call(erlycomet_db, {subscribe, ClientId, ChannelName}).

unsubscribe(ClientId, ChannelName) ->
  gen_server:call(erlycomet_db, {unsubscribe, ClientId, ChannelName}).

channels() ->
  gen_server:call(erlycomet_db, {channels}).

deliver_to_connection(ClientId, Channel, Data) ->
  gen_server:call(erlycomet_db, {deliver_to_connection, ClientId, Channel, Data}).

deliver_to_channel(Channel, Data) ->
  gen_server:call(erlycomet_db, {deliver_to_channel, Channel, Data}).


