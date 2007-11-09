%% @author Bob Ippolito <bob@mochimedia.com>
%% @copyright 2007 Mochi Media, Inc.
%%
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without restriction,
%% including without limitation the rights to use, copy, modify, merge,
%% publish, distribute, sublicense, and/or sell copies of the Software,
%% and to permit persons to whom the Software is furnished to do
%% so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included
%% in all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
%% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
%% IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
%% CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
%% TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
%% SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
%%
%% @doc MochiWeb socket server.

-module(mochiweb_socket_server).
-author('bob@mochimedia.com').
-behaviour(gen_server).

-export([start/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3,
	 handle_info/2]).
-export([get/2]).

-export([acceptor_loop/1]).

-record(mochiweb_socket_server,
	{port,
	 loop,
	 name=undefined,
	 max=2048,
	 ip=any,
	 listen=null,
	 acceptor=null}).

start(State=#mochiweb_socket_server{}) ->
    start_server(State);
start(Options) ->
    start(parse_options(Options)).

get(Name, Property) ->
    gen_server:call(Name, {get, Property}).

stop(Name) when is_atom(Name) ->
    gen_server:cast(Name, stop);
stop(Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, stop);
stop({local, Name}) ->
    stop(Name);
stop({global, Name}) ->
    stop(Name);
stop(Options) ->
    State = parse_options(Options),
    stop(State#mochiweb_socket_server.name).

%% Internal API

parse_options(Options) ->
    parse_options(Options, #mochiweb_socket_server{}).

parse_options([], State) ->
    State;
parse_options([{name, L} | Rest], State) when is_list(L) ->
    Name = {local, list_to_atom(L)},
    parse_options(Rest, State#mochiweb_socket_server{name=Name});
parse_options([{name, A} | Rest], State) when is_atom(A) ->
    Name = {local, A},
    parse_options(Rest, State#mochiweb_socket_server{name=Name});
parse_options([{name, Name} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{name=Name});
parse_options([{port, L} | Rest], State) when is_list(L) ->
    Port = list_to_integer(L),
    parse_options(Rest, State#mochiweb_socket_server{port=Port});
parse_options([{port, Port} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{port=Port});
parse_options([{ip, Ip} | Rest], State) ->
    ParsedIp = case Ip of
		   any ->
		       any;
		   Ip when is_tuple(Ip) ->
		       Ip;
		   Ip when is_list(Ip) ->
		       {ok, IpTuple} = inet_parse:address(Ip),
		       IpTuple
	       end,
    parse_options(Rest, State#mochiweb_socket_server{ip=ParsedIp});
parse_options([{loop, Loop} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{loop=Loop});
parse_options([{max, Max} | Rest], State) ->
    MaxInt = case Max of
		 Max when is_list(Max) ->
		     list_to_integer(Max);
		 Max when is_integer(Max) ->
		     Max
	     end,
    parse_options(Rest, State#mochiweb_socket_server{max=MaxInt}).

start_server(State=#mochiweb_socket_server{name=Name}) ->
    case Name of
	undefined ->
	    gen_server:start_link(?MODULE, State, []);
	_ ->
	    gen_server:start_link(Name, ?MODULE, State, [])
    end.

init(State=#mochiweb_socket_server{ip=Ip, port=Port}) ->
    process_flag(trap_exit, true),
    BaseOpts = [binary, 
		{reuseaddr, true},
		{packet, 0},
		{backlog, 30},
		{recbuf, 8192},
		{active, false}],
    Opts = case Ip of
	       any ->
		   BaseOpts;
	       Ip ->
		   [{ip, Ip} | BaseOpts]
	   end,
    case gen_tcp:listen(Port, Opts) of
	{ok, Listen} ->
	    {ok, ListenPort} = inet:port(Listen),
	    {ok, new_acceptor(State#mochiweb_socket_server{listen=Listen,
							   port=ListenPort})};
	{error, Reason} ->
	    {stop, Reason}
    end.

new_acceptor(State=#mochiweb_socket_server{max=0}) ->
    io:format("Not accepting new connections~n"),
    State#mochiweb_socket_server{acceptor=null};
new_acceptor(State=#mochiweb_socket_server{listen=Listen,loop=Loop}) ->
    Pid = proc_lib:spawn_link(?MODULE, acceptor_loop,
			      [{self(), Listen, Loop}]),
    State#mochiweb_socket_server{acceptor=Pid}.

acceptor_loop({Server, Listen, Loop}) ->
    case catch gen_tcp:accept(Listen) of
	{ok, Socket} ->
	    gen_server:cast(Server, {accepted, self()}),
	    Loop(Socket);
	{error, closed} ->
	    exit({error, closed});
	Other ->
	    error_logger:error_report(
	      [{application, mochiweb},
	       "Accept failed error",
	       lists:flatten(io_lib:format("~p", [Other]))]),
	    exit({error, accept_failed})
    end.
	    

do_get(port, #mochiweb_socket_server{port=Port}) ->
    Port.
    
handle_call({get, Property}, _From, State) ->
    Res = do_get(Property, State),
    {reply, Res, State};
handle_call(_Message, _From, State) ->
    Res = error,
    {reply, Res, State}.

handle_cast({accepted, Pid},
	    State=#mochiweb_socket_server{acceptor=Pid, max=Max}) ->
    % io:format("accepted ~p~n", [Pid]),
    State1 = State#mochiweb_socket_server{max=Max - 1},
    {noreply, new_acceptor(State1)};
handle_cast(stop, State) ->
    {stop, normal, State}.

terminate(_Reason, #mochiweb_socket_server{listen=Listen}) ->
    gen_tcp:close(Listen),
    ok.

code_change(_OldVsn, State, _Extra) ->
    State.

handle_info({'EXIT', Pid, normal},
	    State=#mochiweb_socket_server{acceptor=Pid}) ->
    % io:format("normal acceptor down~n"),
    {noreply, new_acceptor(State)};
handle_info({'EXIT', Pid, Reason},
	    State=#mochiweb_socket_server{acceptor=Pid}) ->
    error_logger:error_report({?MODULE, ?LINE,
			       {acceptor_error, Reason}}),
    timer:sleep(100),
    {noreply, new_acceptor(State)};
handle_info({'EXIT', _LoopPid, Reason},
	    State=#mochiweb_socket_server{acceptor=Pid, max=Max}) ->
    case Reason of 
	normal ->
	    ok;
	_ ->
	    error_logger:error_report({?MODULE, ?LINE,
				       {child_error, Reason}})
    end,
    State1 = State#mochiweb_socket_server{max=Max + 1},
    State2 = case Pid of
		 null ->
		     new_acceptor(State1);
		 _ ->
		     State1
	     end,
    {noreply, State2};
handle_info(Info, State) ->
    error_logger:info_report([{'INFO', Info}, {'State', State}]),
    {noreply, State}.
