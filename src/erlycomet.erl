-module(erlycomet).
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
         subscriber_pids/1,
         deliver_to_connection/3,
         deliver_to_channel/2]).

add_connection(ClientId, Pid) ->
  gen_server:call(erlycomet_store, {add_connection, ClientId, Pid}).
  
replace_connection(ClientId, Pid, State) ->
  gen_server:call(erlycomet_store, {replace_connection, ClientId, Pid, State}).
  
connections() ->
  gen_server:call(erlycomet_store, {connections}).

connection(ClientId) ->
  gen_server:call(erlycomet_store, {connection, ClientId}).

connection_pid(ClientId) ->
  gen_server:call(erlycomet_store, {connection_pid, ClientId}).
  
remove_connection(ClientId)  ->
   gen_server:call(erlycomet_store, {remove_connection, ClientId}).

subscribe(ClientId, ChannelName) ->
  gen_server:call(erlycomet_store, {subscribe, ClientId, ChannelName}).

unsubscribe(ClientId, ChannelName) ->
  gen_server:call(erlycomet_store, {unsubscribe, ClientId, ChannelName}).

channels() ->
  gen_server:call(erlycomet_store, {channels}).

subscriber_pids(Channel) ->
  gen_server:call(erlycomet_store, {subscriber_pids, Channel}).
  
%%--------------------------------------------------------------------
%% @spec (string(), string(), tuple()) -> ok | {error, connection_not_found} 
%% @doc
%% delivers data to one connection
%% @end 
%%--------------------------------------------------------------------  
deliver_to_connection(ClientId, Channel, Data) ->
  Event = {struct, [{channel, Channel},  {data, Data}]},
  case connection_pid(ClientId) of
    undefined -> {error, connection_not_found};
    Pid ->
      Pid ! {flush, Event},
      ok
  end.


%%--------------------------------------------------------------------
%% @spec  (string(), tuple()) -> ok | {error, channel_not_found} 
%% @doc
%% delivers data to all connections of a channel
%% @end 
%%--------------------------------------------------------------------
deliver_to_channel(Channel, Data) ->
  globbing(fun deliver_to_single_channel/3, Channel, Data).


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

globbing(Fun, Channel, Data) ->
  ChannelString = binary_to_list(Channel),
  lists:map(fun(SubscriberChannel) ->
    case lists:reverse(binary_to_list(SubscriberChannel)) of
      [$*, $* | T] ->
        case string:str(ChannelString, lists:reverse(T)) of
          1 ->
            Fun(SubscriberChannel, Channel, Data);
          _ ->
            skip
        end;
      [$* | T] ->
          case string:str(ChannelString, lists:reverse(T)) of
            1 ->
              Tokens = string:tokens(string:sub_string(ChannelString, length(T) + 1), "/"),
              case Tokens of
                [_] ->
                  Fun(SubscriberChannel, Channel, Data);
                _ ->
                  skip
              end;
            _ ->
              skip
          end;
      _ ->
        Fun(Channel, Channel, Data)
    end
  end,
  channels()).


deliver_to_single_channel(SubscriberChannel, Channel, Data) ->  
  Event = {struct, [{channel, Channel}, {data, Data}]},
  case subscriber_pids(SubscriberChannel) of
    [] -> ok;
    Pids ->
      [send_event(Pid, Event) || Pid <- Pids],
      ok
  end.


send_event(Pid, Event) when is_pid(Pid)->
  Pid ! {flush, Event};
send_event(_, _) ->
  ok.
