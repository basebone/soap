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
%%% The functions that are called by the client module that is generated by
%%% wsdl2erlang.
%%%
%%% This implements a kind of generic HTTP client interface. Via this interface 
%%% the selected HTTP client application is called.
%%%
-module(soap_client_util).

-include("soap.hrl").

-export([call/5]).
-export([call/6]).

%%% ============================================================================
%%% Types
%%% ============================================================================
-type prefix() :: string().
-type option() :: {url, string()}.
-type uri() :: string().

-type soap_response() :: soap:soap_response(any()).
-type soap_attachment() :: soap:soap_attachment().

%% the p_state{} record is used during the decoding 
%% of the response message.
-record(p_state, {
    model :: erlsom:model(),
    handler :: module(),
    version :: '1.1' | '1.2',
    soap_ns :: string(),
    state :: atom(),
    parser :: fun(),
    header_parser :: fun(),
    fault_parser :: fun(),
    parser_state :: any(),
    soap_headers = [] :: [string() | tuple()],
    soap_body :: string() | tuple(),
    is_fault = false :: boolean(),
    namespaces = [] :: [{prefix(), uri()}]
}).

-define(CONTENT_TYPE, "text/xml;charset=utf-8").
-define(CONTENT_TYPE_12, "application/soap+xml;charset=utf-8").


%%% ============================================================================
%%% Exported functions
%%% ============================================================================

%% Call a service. 
%% The "Interface" argument contains information about the service (input, 
%% output, URL, type specification in the form of an erlsom model...).
-spec call(Body::tuple(), Headers::[any()], Options::[option()], 
           Soap_action::string(), interface()) -> soap_response().
call(Body, Headers, Options, Soap_action, Interface) ->
    call(Body, Headers, Options, Soap_action, Interface, []).

%% This one is with attachments. This version is used if the 'attachments'
%% option is passed to wsdl2soap.
-spec call(Body::tuple(), Headers::[any()], Options::[option()], 
           Soap_action::string(), interface(), [soap_attachment()]) -> soap_response().
call(Body, Headers, Options, Soap_action, 
         #interface{model = Model} = Interface, Attachments) ->
    Interface2 = process_options(Options, Interface),
    case encode_headers(Headers, Model) of
        {ok, Encoded_headers} ->
            call_body(Body, Encoded_headers, Soap_action, Interface2, Attachments);
        Error ->
            Error
    end.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

call_body(Body, [], Soap_action, Interface, Attachments)
    when not is_tuple(Body) ->
    call_message(Body, Soap_action, Interface, Attachments);
call_body(Body, Encoded_headers, Soap_action, 
          #interface{model = Model, soap_ns = Namespace} = Interface,
          Attachments) ->
    try
        erlsom:write(Body, Model)
    of
        {ok, Encoded_body} ->
            Http_body = 
                ["<s:Envelope xmlns:s=\"", Namespace, "\">",
                    Encoded_headers,
                    "<s:Body>",
                    unicode:characters_to_binary(Encoded_body),
                    "</s:Body></s:Envelope>"],
            call_message(Http_body, Soap_action, Interface, Attachments)
    catch
        Class:Error ->
            {error, {client, {encoding_body, Class, Error}}, <<>>}
    end.

        
call_message(Http_body, Soap_action, 
             #interface{http_options = Http_client_options,
                        version = Version} = Interface, 
             Attachments) ->
    Http_headers = proplists:get_value(http_headers, Http_client_options, []),
    Content_type = content_type(Version),
    Message_headers = 
        case Version of 
            '1.1' ->
                [{"SOAPAction", Soap_action} | Http_headers]; 
            '1.2' ->
                Http_headers
        end,
    case Attachments of
        [] ->
            call_http(Http_body, Interface, Message_headers, Content_type);
        _ ->
            Mime_headers = [{"Content-type", Content_type} | Message_headers],
            Mime_body = soap_mime:mime_body(Http_body, Mime_headers, Attachments),
            call_http(Mime_body, Interface, [], soap_mime:mime_content_type())
    end.


%% For the options that overwrite values that are part of the 
%% #interface{} record.
process_options(Options, #interface{http_options = Http_opts} = Interface) ->
    F = fun
            ({url, Url}, Interf) ->
                Interf#interface{url = Url};
            ({http_headers, _} = Header_opt, Interf) ->
                Interf#interface{http_options = [Header_opt | Http_opts]};
            ({http_options, Values}, Interf) ->
                Interf#interface{http_options = Values ++ Http_opts};
            ({version, Version}, Interf) ->
                Interf#interface{version = Version,
                                 soap_ns = soap_ns(Version)};
            ({log, LogItems}, Interf) ->
                Interf#interface{userlogitems = LogItems};
            (_, Interf) ->
                Interf
        end,
    lists:foldl(F, Interface, Options).

soap_ns('1.1') -> ?SOAP_NS;
soap_ns('1.2') -> ?SOAP12_NS.

call_http(Http_body, 
          #interface{model = Model, 
                     http_client = Client,
                     http_options = Http_client_options,
                     client_handler = Handler,
                     soap_ns = Ns,
                     version = Version,
                     url = Url,
                     userlogitems=UserLog}, Http_headers, Content_type) ->
    %%io:format("request: ~nheaders: ~p~nbody: ~s~n", [Http_headers, Http_body]),    
    %%erlang:display(lists:flatten(Http_body)),
    Http_res = Client:http_request(Url, Http_body, Http_client_options, 
                                   Http_headers, Content_type),
    lager:info([{audit, true}], "Soap Audit logging: UserItems ~p Url ~p Headers ~p Request ~p Response ~p", [UserLog, Url, Http_headers, iolist_to_binary(Http_body), Http_res]),
    case Http_res of
        {ok, Code, Response_headers, Response_body} 
            when Code == 200; Code == 500 ->
            %%io:format("response: code: ~p~nheaders: ~p~nbody: ~s~n", 
            %%  [Code, Response_headers, 
            %%   binary_to_list(Response_body)]),
            parse_message(Response_body, Model, Code, Response_headers, 
                          Version, Ns, Handler);
        {ok, Code, Response_headers, Response_body} ->
            {error, {server, Code, Response_headers}, Response_body};
        {error, Error} ->
            %% in case of HTTP error: return
            %% {error, description}
            {error, {client, {http_request, Error}}, <<>>}
    end.

content_type('1.1') ->
    ?CONTENT_TYPE;
content_type('1.2') ->
    ?CONTENT_TYPE_12.

%% encode the SOAP headers to XML
encode_headers([], _) ->
    {ok, []};
encode_headers(Headers, Model) ->
    encode_headers(Headers, Model, []).
encode_headers([], _, Acc) ->
    {ok, ["<s:Header>",
     lists:reverse(Acc),
     "</s:Header>"]};
encode_headers([Header|T], Model, Acc) 
    when is_list(Header); is_binary(Header) ->
    encode_headers(T, Model, [Header | Acc]);
%% If the SOAP header block is represented as a tuple, it must be
%% a type that can be encoded by the erlsom model in the 
%% interface(). That is, it must be an element in the Types 
%% section of the WSDL.
encode_headers([Header|T], Model, Acc) when is_tuple(Header) ->
    case erlsom:write(Header, Model) of
        {ok, Encoded_header} ->
            encode_headers(T, Model, 
                           [unicode:characters_to_binary(Encoded_header) | Acc]);
        Error ->
            {error, {client, {encoding_headers, {Error}}}}
    end.

parse_message(Message, Model, Http_status, Http_headers, Version, Ns, Handler) ->
    case lists:keyfind("Content-Type", 1, Http_headers) of 
        false ->
            parse_xml(Message, Model, Http_status, Http_headers, 
                      Version, Ns, Handler, [], Message);
        {_, Content_type} ->
            case string:to_lower(lists:sublist(Content_type, 17)) of
                "multipart/related" ->
                    parse_mime(Message, Model, Http_status, Http_headers, 
                               Version, Ns, Handler, Content_type);
                _ ->
                    parse_xml(Message, Model, Http_status, Http_headers, 
                              Version, Ns, Handler, [], Message)
            end
    end.

parse_mime(Message, Model, Http_status, Http_headers, 
           Version, Ns, Handler, Content_type_header) ->
    % see what comes after "multipart/related"
    Mime_parameters = lists:nthtail(17, Content_type_header),
    Parsed_parameters = soap_mime:parse_mime_parameters(Mime_parameters),
    case proplists:get_value("boundary", Parsed_parameters) of
        undefined ->
            parse_xml(Message, Model, Http_status, Http_headers, 
                      Version, Ns, Handler, [], Message);
        Boundary ->
            case soap_mime:decode(Message, list_to_binary(Boundary)) of
                [{Headers, Body} | Attachments] ->
                    parse_xml(Body, Model, Http_status, Headers, 
                              Version, Ns, Handler, Attachments, Message);
                _Other ->
                    {error, {client, decoding_mime}}
            end
    end.


parse_xml(Message, Model, Http_status, Http_headers, 
          Version, Ns, Handler, Attachments, HTTP_body) ->
    %%io:format("Before Parse: ~p ~p ~p",[Message, Version, Ns]),
    try erlsom:parse_sax(Message, 
                         #p_state{model = Model, version = Version,
                                  soap_ns = Ns, state = start,
                                  handler = Handler},
                         fun xml_parser_cb_wrapped/2, []) of
        {ok, #p_state{is_fault = true,
                      soap_headers = Decoded_headers,
                      soap_body = Decoded_fault,
                      version = Version}, _} ->
            {fault, Http_status, Http_headers, Decoded_headers, 
                    Decoded_fault, Attachments, HTTP_body};
        {ok, #p_state{soap_body = Decoded_body,
                      soap_headers = Decoded_headers}, _} ->
            {ok, Http_status, Http_headers, Decoded_headers, 
                 Decoded_body, Attachments, HTTP_body}
    catch
        %% For now: assume that this means invalid XML
        %% TODO: differentiate more (perhaps improve erlsom error codes)
        Class:Reason ->
            {error, {client, {parsing_message, Http_status, 
                              Http_headers, Class, Reason}}, HTTP_body}
    end.

%% This wrapped version exists only to facilitate debugging
xml_parser_cb_wrapped(Event, #p_state{state = _P_state} = S) ->
    xml_parser_cb(Event, S).

%% Peels off the envelope and decodes headers and body.
%%
%% This is an erlsom - sax callback function. It is called for every SAX 
%% event. It keeps track of the progress of the parsing in the #p_state{}
%% record.
%%
%% The SOAP envelope is parsed by this function. For the contents (header
%% blocks and body), the sax events are handed over to another sax callback
%% function. Which one that is, is specified by the handler module for the 
%% service.
%%
xml_parser_cb({startPrefixMapping, Prefix, URI}, 
              #p_state{namespaces = N_spaces} = S) ->
    S#p_state{namespaces = [{Prefix, URI} | N_spaces]};
xml_parser_cb({endPrefixMapping, Prefix}, 
              #p_state{namespaces = N_spaces} = S) ->
    S#p_state{namespaces = lists:keydelete(Prefix, 1, N_spaces)};
xml_parser_cb(startDocument, #p_state{state = start} = S) ->
    S#p_state{state = started};
xml_parser_cb(startDocument, #p_state{state = started} = S) ->
    S#p_state{state = started};
xml_parser_cb({startElement, Ns, "Envelope", _Prfx, _Attrs},
              #p_state{state = started,
                       soap_ns = Ns} = S) ->
    S#p_state{state = envelope};
xml_parser_cb({startElement, Ns, "Header", _Prfx, _Attrs},
              #p_state{state = envelope,
                       soap_ns = Ns} = S) ->
    S#p_state{state = header};
xml_parser_cb({endElement, NS, "Header", _Prfx},
              #p_state{state = header,
                       soap_ns = NS} = S) ->
    %% empty header
    S#p_state{state = envelope};
xml_parser_cb({startElement, Namespace, _LocalName, _Prfx, _Attrs} = Event,
              #p_state{state = header, handler = Handler} = S) ->
    {ok, {Header_parser, Start_state}} = get_header_parser(Handler, Namespace),
    %% a new "startDocument" event is injected to get the header parser going.
    S1 = parse_event(Header_parser, startDocument, Start_state),
    %% and the event that we just received from the sax parser is recycled
    S2 = parse_event(Header_parser, Event, S1),
    S#p_state{state = parsing_header, parser_state = S2,
              header_parser = Header_parser};
xml_parser_cb({endElement, NS, "Header", _Prfx},
              #p_state{state = parsing_header, 
                       soap_headers = Headers,
                       soap_ns = NS} = S) ->
    S#p_state{state = envelope, soap_headers = lists:reverse(Headers)}; 
xml_parser_cb(Event, #p_state{state = parsing_header, 
                              header_parser = H_parser, 
                              soap_headers = Headers,
                              parser_state = P_state} = S) ->
    %% all events that are part of the header are passed to the header parser.
    case H_parser(Event, P_state) of
        %% reached the end of this header. The header parser signals this 
        %% by using the form {result, _}.
        {result, undefined} -> %% undefined is treated as a special value,
                               %% this header is ignored.
            S#p_state{state = header, parser_state = undefined};
        {result, Parsed_header} ->
            S#p_state{state = header, parser_state = undefined, 
                      soap_headers = [Parsed_header | Headers]};
        P_state2 ->
            S#p_state{parser_state = P_state2}
    end;
xml_parser_cb({startElement, Ns, "Body", _Prfx, _Attrs},
              #p_state{state = envelope,
                       soap_ns = Ns} = S) ->
    S#p_state{state = body};
xml_parser_cb({startElement, Ns, "Fault", _Prfx, _Attrs} = Event,
              #p_state{state = body,
                       version = Version,
                       namespaces = Namespaces,
                       soap_ns = Ns} = S) ->
    Start_state = soap_fault:parse_fault_start(Version),
    Fault_parser = fun soap_fault:parse_fault/3,
    S1 = parse_event(Fault_parser, startDocument, Namespaces, Start_state),
    %% the event that we just received from the sax parser is recycled
    S2 = parse_event(Fault_parser, Event, Namespaces, S1),
    S#p_state{state = parsing_fault, is_fault = true, 
              fault_parser = Fault_parser, parser_state = S2};

%% parsing the body
xml_parser_cb({startElement, _Namespace, _LocalName, _Prfx, _Attrs} = Event,
              #p_state{state = body, 
                       model = Model, 
                       namespaces = N_spaces} = S) ->
    Callback_state = erlsom_parse:new_state(Model, N_spaces),
    %% a new "startDocument" event is injected to get the body parser going.
    S1 = erlsom_parse:xml2StructCallback(startDocument, Callback_state),
    S2 = erlsom_parse:xml2StructCallback(Event, S1),
    S#p_state{state = parsing_body, parser_state = S2, 
              parser = fun erlsom_parse:xml2StructCallback/2};
xml_parser_cb({endElement, Ns, "Body", _Prfx},
              #p_state{state = body,
                       soap_ns = Ns} = S) ->
    %% empty body
    S#p_state{state = body_done};
xml_parser_cb({endElement, Ns, "Body", _Prfx},
              #p_state{state = parsing_body, 
                       parser = Parser,
                       soap_ns = Ns,
                       parser_state = P_state} = S) ->
    %% the end of the body, send an "endDocument" event to the body parser.
    Parsed_body = Parser(endDocument, P_state),
    S#p_state{state = body_done, parser_state = undefined,
              soap_body = Parsed_body};
xml_parser_cb(Event, #p_state{state = parsing_body, 
                              parser = Parser,
                              parser_state = P_state} = S) ->
    %% all events that are part of the body are passed to the body parser.
    S#p_state{parser_state = Parser(Event, P_state)};

%% reached the end of the message
xml_parser_cb(endDocument, State) ->
    State;

%% parsing a fault
xml_parser_cb({endElement, Ns, "Fault", _Prfx} = Event,
              #p_state{state = parsing_fault, 
                       fault_parser = Parser,
                       soap_ns = Ns,
                       namespaces = Namespaces,
                       parser_state = P_state} = S) ->
    %% The parser needs the end-tag of the fault
    S2 = Parser(Event, Namespaces, P_state),
    %% send an "endDocument" event to the fault parser.
    Parsed_fault = Parser(endDocument, Namespaces, S2),
    S#p_state{state = body_done, parser_state = undefined,
              soap_body = Parsed_fault};
xml_parser_cb(Event, #p_state{state = parsing_fault, 
                              fault_parser = Parser,
                              namespaces = Namespaces,
                              parser_state = P_state} = S) ->
    %% all events that are part of the body are passed to the fault parser.
    S#p_state{parser_state = Parser(Event, Namespaces, P_state)};

%% ignore other stuff
xml_parser_cb(_, #p_state{state = P_state} = S)
    when P_state /= parsing_body, 
         P_state /= parsing_header,
         P_state /= parsing_fault ->
    S.


parse_event(Parser, Event, State) ->
    try 
        Parser(Event, State)
    catch
        %% TODO: ensure that XML parsers provide uniform error codes, in 
        %% particular in case of malformed XML (erlsom sax).
        Class:Reason ->
            throw({header_parser, Class, Reason})
    end.

parse_event(Parser, Event, Namespaces, State) ->
    try 
        Parser(Event, Namespaces, State)
    catch
        Class:Reason ->
            throw({header_parser, Class, Reason})
    end.

%% get a callback function (a fun) from the handler module,
%% if it exists.
get_function(Module, Function, Arity, Default) ->
    case erlang:function_exported(Module, Function, Arity) of
        true ->
            fun Module:Function/Arity;
        false ->
            Default
    end.

get_header_parser(Handler, Namespace) ->
    Default = fun default_header_parser/1,
    Selector = get_function(Handler, header_parser, 1, Default),
    try 
        {ok, {_, _}} = Selector(Namespace)
    catch
        error:undef ->
            Default(Namespace);
        error:function_clause ->
            Default(Namespace);
        Class:Reason ->
            throw({get_header_parser, Class, Reason})
    end.

default_header_parser(_Namespace) ->    
    %% soap_parsers:skip(undefined) ignores the value of the header block, and 
    %% returns 'undefined' when the parsing is doen. 'undefined' is treated as 
    %% a special value (see above), which will not be included in the result.
    {ok, soap_parsers:skip(undefined)}.
