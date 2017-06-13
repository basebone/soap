%%
%% %CopyrightBegin%
%%
%% Copyright Hillside Technology Ltd. 2016. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%%%
%%% SOAP handler for Cowboy, version 2. 
%%% Takes care of the SOAP specific stuff such as decoding and encoding the
%%% xml, some error handling on the level of the soap protocol, etc.
%%%
%%% Most of the logic is shared between cowboy v.1 and cowboy v.2, in the module 
%%% 'soap_cowboy_protocol'. 

-module(soap_cowboy_2_protocol).
%%-behaviour(cowboy_sub_protocol).

-export([upgrade/4]).
-export([enrich_req/2]).
-export([respond/4]).

-type cowboy_req() :: cowboy_req:req().
-type cowboy_env() :: cowboy_middleware:env().

-record(state, {
  env :: cowboy_middleware:env(),
  handler = undefined :: undefined | module()
}).

%%% ============================================================================
%%% Exported functions
%%% ============================================================================

%% This is the callback of the cowboy_sub_protocol behaviour.
%%
%% From the Cowboy documentation:
%% This callback is expected to behave like a middleware and to return an
%% updated req object and environment.
-spec upgrade(Cowboy_req::cowboy_req(), Env::cowboy_env(),
              Soap_handler::module(), Options::any()) -> {ok, cowboy_req(), cowboy_env()}. 
upgrade(Cowboy_req, Env, _, {Handler, Options}) ->
  Cowboy_state = #state{env = Env, handler = Handler},
  case soap_server_handler:new_req(Handler, soap_cowboy_2_protocol, Options, Cowboy_req) of
    {continue, Soap_req} ->
      check_conformance(Soap_req, Cowboy_req, Cowboy_state, soap_cowboy_2_protocol);
    {ok, _StatusCode, _Headers, _Body, _Server_req} = Error ->
      make_response(Error, Cowboy_state, soap_cowboy_2_protocol)
  end.

enrich_req(Cowboy_req, Soap_req) ->
  Method = cowboy_req:method(Cowboy_req),
  Soap_req2 = soap_req:set_method(Soap_req, make_list(Method)),
  Content_type = cowboy_req:header(<<"content-type">>, Cowboy_req),
  Soap_req3 = soap_req:set_content_type(Soap_req2, make_list(Content_type)),
  Soap_action = cowboy_req:header(<<"soapaction">>, Cowboy_req),
  soap_req:set_soap_action(Soap_req3, make_list(Soap_action)).

respond(Cowboy_req, Env, Handler, StatusCode) ->
  Req2 = cowboy_req:reply(StatusCode, Cowboy_req),
  terminate(Req2, Env, Handler).

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

make_list(undefined) ->
  undefined;
make_list(Binary) ->
  binary_to_list(Binary).

terminate(Cowboy_req, Env, Handler) ->
  Result = cowboy_handler:terminate(normal, Cowboy_req, [], Handler),
  {ok, Cowboy_req, [{result, Result}|Env]}.

check_conformance(Soap_req, Cowboy_req, Cowboy_state, Version_module) ->
  %% collect some information about the protocol, so that 
  %% conformance can be checked.
  Soap_req2 = Version_module:enrich_req(Cowboy_req, Soap_req),
  case soap_server_handler:check_http_conformance(Soap_req2) of
    {continue, Soap_req3} ->
      handle_xml(Soap_req3, Cowboy_state, Version_module);
    {ok, _StatusCode, _Headers, _Body, _Server_req} = Error ->
      make_response(Error, Cowboy_state, Version_module)
  end.

handle_xml(Soap_req, Cowboy_state, Version_module) ->
  Cowboy_req = soap_req:server_req(Soap_req),
  {ok, Message, Cowboy_req2} = cowboy_req:read_body(Cowboy_req),
  Soap_req2 = soap_req:set_server_req(Soap_req, Cowboy_req2),
  Soap_req3 = soap_req:set_http_body(Soap_req2, Message),
  Content_type = soap_req:content_type(Soap_req3),
  %% get the soap message (Xml) from the request body
  {Xml, Soap_req4} = case maybe_content_type(Content_type) of
    "multipart/related" -> 
        %% soap with attachments, the message is in the first part
        try 
          [{Mime_headers, Body} | Attachments] =
            mime_decode(Message, Content_type),
            {Body, 
             soap_req:set_mime_headers(
               soap_req:set_req_attachments(Soap_req3, Attachments), 
               Mime_headers)}
      catch
        _Class:_Type ->
          {Message, Soap_req3}
      end;
    _ ->
      {Message, Soap_req3}
  end,
  Handler_resp = soap_server_handler:handle_message(Xml, Soap_req4),
  make_response(Handler_resp, Cowboy_state, Version_module).

maybe_content_type(undefined) ->
  undefined;
maybe_content_type(Content_type) ->
  string:to_lower(lists:sublist(Content_type, 17)).


mime_decode(Message, Content_type_header) ->
  Mime_parameters = lists:nthtail(17, Content_type_header),
  Parsed_parameters = soap_mime:parse_mime_parameters(Mime_parameters),
  Boundary = proplists:get_value("boundary", Parsed_parameters),
  soap_mime:decode(Message, list_to_binary(Boundary)).

make_response({ok, StatusCode, Headers, Body, Cowboy_req}, #state{env = Env, handler = Handler}, Version_module) ->
  Cowboy_req2 = set_headers(Headers, Cowboy_req),
  Cowboy_req3 = cowboy_req:set_resp_body(Body, Cowboy_req2),
  Version_module:respond(Cowboy_req3, Env, Handler, StatusCode). 

set_headers(Headers, Cowboy_req) ->
  lists:foldl(fun({Name, Value}, R) -> 
                  cowboy_req:set_resp_header(to_binary(Name), Value, R)
              end,
              Cowboy_req, Headers).

to_binary(N) when is_binary(N) ->
  N;
to_binary(N) when is_list(N) ->
erlang:list_to_binary(N).
