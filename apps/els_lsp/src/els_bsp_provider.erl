-module(els_bsp_provider).

-behaviour(els_provider).

%% API
-export([ start/1
        , request/2
        ]).

%% els_provider functions
-export([ is_enabled/0
        , init/0
        , handle_request/2
        , handle_info/2
        ]).


%%==============================================================================
%% Includes
%%==============================================================================
-include("els_lsp.hrl").
-include_lib("kernel/include/logger.hrl").

%%==============================================================================
%% Types
%%==============================================================================
-type state() :: #{ running := boolean()          % is the BSP server running?
                  , root_uri := uri() | undefined % the root uri
                  , pending := list()             % pending requests
                  }.
-type method() :: binary().
-type params() :: map() | null.
-type request_response() :: {reply, any()} | {error, any()}.
-type request_id() :: {reference(), reference(), atom() | pid()}.
-type from() :: {pid(), reference()} | self.
-type config() :: map().

%%==============================================================================
%% API
%%==============================================================================
-spec start(uri()) -> {ok, config()} | {error, term()}.
start(RootUri) ->
  els_provider:handle_request(?MODULE, {start, #{ root => RootUri }}).

-spec request(method(), params()) -> request_response().
request(Method, Params) ->
  RequestId = send_request(Method, Params),
  wait_response(RequestId, infinity).

-spec send_request(method(), params()) -> request_id().
send_request(Method, Params) ->
  Mon = erlang:monitor(process, ?MODULE),
  Ref = erlang:make_ref(),
  From = {self(), Ref},
  els_provider:handle_request(?MODULE, {send_request, #{ from => From
                                                       , method => Method
                                                       , params => Params }}),
  {Ref, Mon, ?MODULE}.

-spec wait_response(request_id(), timeout()) -> request_response() | timeout.
wait_response({Ref, Mon, ServerRef}, Timeout) ->
  receive
    {Ref, Response} ->
      erlang:demonitor(Mon, [flush]),
      Response;
    {'DOWN', Mon,  _Type, _Object, Info} ->
      erlang:demonitor(Mon, [flush]),
      {error, {Info, ServerRef}}
  after Timeout ->
      timeout
  end.

%%==============================================================================
%% els_provider functions
%%==============================================================================
-spec init() -> state().
init() ->
  #{ running  => false
   , root_uri => undefined
   , pending  => []
   }.

-spec is_enabled() -> true.
is_enabled() -> true.

-spec handle_request({start, #{ root := uri() }}, state())
                    -> {{ok, config()}, state()} | {{error, any()}, state()};
                    ({send_request, #{ from := from()
                                     , method := method()
                                     , params  := params() }}, state())
                    -> {ok, state()}.
handle_request({start, #{ root := RootUri }}, #{ running := false } = State) ->
  ?LOG_INFO("Starting BSP server in ~p", [RootUri]),
  case els_bsp_client:start_server(RootUri) of
    {ok, Config} ->
      ?LOG_INFO("BSP server started from config ~p", [Config]),
      {{ok, Config}, initialize_bsp(RootUri, State)};
    {error, Reason} ->
      ?LOG_ERROR("BSP server startup failed: ~p", [Reason]),
      {{error, Reason}, State}
  end;
handle_request({send_request, #{ from := From
                               , method := Method
                               , params := Params }}, State) ->
  {ok, request(From, Method, Params, State)}.

-spec handle_info(any(), state()) -> state().
handle_info(Msg, State) ->
  case check_response(Msg, State) of
    {ok, NewState} ->
      NewState;
    no_reply ->
      ?LOG_WARNING("Discarding unrecognized message: ~p", [Msg]),
      State
  end.

%%==============================================================================
%% Internal functions
%%==============================================================================
-spec initialize_bsp(uri(), state()) -> state().
initialize_bsp(Root, State) ->
  {ok, Vsn} = application:get_key(els_lsp, vsn),
  Params = #{ <<"displayName">>  => <<"Erlang LS BSP Client">>
            , <<"version">>      => list_to_binary(Vsn)
            , <<"bspVersion">>   => <<"2.0.0">>
            , <<"rootUri">>      => Root
            , <<"capabilities">> => #{ <<"languageIds">> => [<<"erlang">>] }
            , <<"data">>         => #{}
            },
  request(<<"build/initialize">>, Params, State#{ running => true
                                                , root_uri => Root }).

-spec request(method(), params(), state()) -> state().
request(Method, Params, State) ->
  request(self, Method, Params, State).

-spec request(from(), method(), params(), state()) -> state().
request(From, Method, Params, #{ pending := Pending } = State) ->
  RequestId = els_bsp_client:request(Method, Params),
  State#{ pending => [{RequestId, From, {Method, Params}} | Pending] }.

-spec handle_response({binary(), any()}, any(), state()) -> state().
handle_response({<<"build/initialize">>, _}, Response, State) ->
  ?LOG_INFO("BSP Server initialized: ~p", [Response]),
  ok = els_bsp_client:notification(<<"build/initialized">>),
  request(<<"workspace/buildTargets">>, #{}, State);
handle_response({<<"workspace/buildTargets">>, _}, Response, State0) ->
  Result = maps:get(result, Response, #{}),
  Targets = maps:get(targets, Result, []),
  TargetIds = lists:flatten([ maps:get(id, Target, []) || Target <- Targets ]),
  Params = #{ <<"targets">> => TargetIds },
  State1 = request(<<"buildTarget/sources">>, Params, State0),
  State2 = request(<<"buildTarget/dependencySources">>, Params, State1),
  State2;
handle_response({<<"buildTarget/sources">>, _}, Response, State) ->
  handle_sources(apps_paths,
                 fun(Source) -> maps:get(uri, Source, []) end,
                 Response,
                 State);
handle_response({<<"buildTarget/dependencySources">>, _}, Response, State) ->
  handle_sources(deps_paths,
                 fun(Source) -> Source end,
                 Response,
                 State);
handle_response(Request, Response, State) ->
  ?LOG_WARNING("Unhandled response. [request=~p] [response=~p]",
               [Request, Response]),
  State.

-spec handle_sources(atom(), fun((any()) -> uri()), map(), state()) -> state().
handle_sources(ConfigKey, SourceFun, Response, State) ->
  Result = maps:get(result, Response, #{}),
  Items = maps:get(items, Result, []),
  Sources = lists:flatten([ maps:get(sources, Item, []) || Item <- Items ]),
  Uris = lists:flatten([ SourceFun(Source) || Source <- Sources ]),
  UriMaps = [ uri_string:parse(Uri) || Uri <- Uris ],
  NewPaths = lists:flatten([ maps:get(path, UM, []) || UM <- UriMaps ]),
  OldPaths = els_config:get(ConfigKey),
  AllPaths = lists:usort([ els_utils:to_list(P) || P <- OldPaths ++ NewPaths]),
  els_config:set(ConfigKey, AllPaths),
  els_indexing:start(),
  State.

-spec check_response(any(), state()) -> {ok, state()} | no_reply.
check_response(Msg, #{ pending := Pending } = State) ->
  F = fun({RequestId, From, Request}) ->
          case els_bsp_client:check_response(Msg, RequestId) of
            no_reply ->
              true;
            {reply, _Reply} ->
              false;
            {error, Reason} ->
              ?LOG_ERROR("BSP request error. [from=~p] [request~p] [error=~p]",
                         [From, Request, Reason]),
              false
          end
      end,
  case lists:splitwith(F, Pending) of
    {_, []} ->
      no_reply;
    {Left, [{RequestId, From, Request} | Right]} ->
      Result = els_bsp_client:check_response(Msg, RequestId),
      NewState = State#{ pending => Left ++ Right },
      case {From, Result} of
        {{Pid, Ref}, Result} ->
          try Pid ! {Ref, Result} catch _:_ -> ok end,
          {ok, NewState};
        {self, {reply, Reply}} ->
          {ok, handle_response(Request, Reply, NewState)};
        {self, {error, _Reason}} ->
          {ok, NewState}
      end
  end.
