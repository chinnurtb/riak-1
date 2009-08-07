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

%% @doc jiak_resource provides access to Jiak objects over HTTP.
%%      Resources are provided at URIs shaped like:
%%        ```http://host/JiakBase/Bucket/Key'''
%%      That is, an object stored in the Riak bucket "Bucket" at key
%%      "Key" would be available at the path Bucket/Key, relative to
%%      jiak_resource's base path.
%%
%%      jiak_resource should be added to a Webmachine dispatch with
%%      two lines, one for bucket-targetted requests, the other for
%%      item-targetted requests:
%%<pre>
%%      {[JiakBase,bucket], jiak_resource,
%%       [{key_type, container}|Options]}.
%%      {[JiakBase,bucket,key], jiak_resource,
%%       [{key_type, item}|Options]}.
%%</pre>
%%
%%      Dispatch Configuration Options:
%%<dl><dt>  {jiak_name, string()}: (Required)
%%</dt><dd>   base path for jiak_resource
%%</dd><dt> {key_type, item|container}: (Required)
%%</dt><dd>   set to 'item' when the request path targets a specific
%%            object, or to 'container' when it targets a whole bucket
%%</dd><dt> {riak_local, boolean()}: (Optional)
%%</dt><dd>   set to 'true' to use jiak:local_client/0, otherwise
%%            jiak:client_connect/3 will be used
%%</dd><dt> {riak_ip, string()}: (Required if riak_local = false)
%%</dt><dd>   IP of the riak cluster, passed to jiak:client_connect/3
%%</dd><dt> {riak_port, integer()}: (Required if riak_local = false)
%%</dt><dd>   Port of the riak cluster, passed to jiak:client_connect/3
%%</dd><dt> {riak_cookie, atom()}: (Required if riak_local = false)
%%</dt><dd>   Cookie of the riak cluster, passd to jiak:client_connect/3
%%</dd></dl>
%%
%%      HTTP Query Parameters:
%%<dl><dt>  schema
%%</dt><dd>   allowed values: true (default), false
%%            when GETting a bucket, set schema=false if you do not
%%            want the schema included in the response
%%</dd><dt> keys
%%</dt><dd>   allowed values: true (default), false
%%            when GETting a bucket, set keys=false if you do not want
%%            the keylist included in the response
%%</dd><dt> returnbody
%%</dt><dd>   allowed values: true, false (default)
%%            when PUTting or POSTing an object, set returnbody=true
%%            if you want the response to included the updated object
%%            (saves the roundtrip for a subsequent GET), the response
%%            will be 204 No Content, otherwise
%%</dd><dt> r
%%</dt><dd>   specify the Riak R value for get operations
%%</dd><dt> w
%%</dt><dd>   specify the Riak W value for put operations
%%</dd><dt> dw
%%</dt><dd>   specify the Riak DW value for put operations
%%</dd><dt> rw
%%</dt><dd>   specify the Riak RW value for delete operations
%%</dd></dl>
%%
%%      HTTP Usage:
%%<dl><dt> GET /JiakBase/Bucket
%%</dt><dd>  If the bucket is listable, returns a JSON object
%%           of the form:
%%           {
%%            "schema":{
%%                      "allowed_fields":["FieldName1","FieldName2",...],
%%                      "required_fields":["FieldName1",...],
%%                      "write_mask":["FieldName1",...],
%%                      "read_mask":["FieldName1",...]
%%                     },
%%            "keys":["Key1","Key2",...]
%%           }
%%           Each element of the "schema" lists some fo the field names
%%           defined for objects of the requested bucket.
%%<dl><dt>     allowed_fields
%%</dt><dd>      Objects may only include the fields listed here
%%</dd><dt>    required_fields
%%</dt><dd>      Objects must have fields listed here
%%</dd><dt>    write_mask
%%</dt><dd>      Clients may change only the fields listed here
%%</dd><dt>    read_mask
%%</dt><dd>      Clients will see only the contents of fields listed here
%%</dd></dl>
%%
%%</dd><dt> GET /JiakBase/Bucket/Key
%%</dt><dd>   If the object exists, and access is permitted, returns
%%            the object JSON-encoded
%%
%%</dd><dt> PUT /JiakBase/Bucket/Key
%%</dt><dd>   Store the object in the request body in the given Bucket at
%%            the given Key.  The "bucket" and "key" fields in the object
%%            must match the Bucket and Key components of the URI.
%%
%%</dd><dt> POST /JiakBase/Bucket
%%</dt><dd>   Store the object in the request body in the given Bucket at
%%            a new, server-generated key.  Response will be empty (unless
%%            returnbody=true is specified in the query parameters) with
%%            the Location header set to the new object's URI.
%%</dd></dl>
-module(jiak_resource).

-export([init/1,
         allowed_methods/2,
         resource_exists/2,
         is_authorized/2,
         content_types_provided/2,
         content_types_accepted/2,
         encodings_provided/2,
         post_is_create/2,
         create_path/2,
         handle_incoming/2,
         produce_body/2,
         delete_resource/2,
         malformed_request/2,
         forbidden/2,
	 last_modified/2,
	 generate_etag/2,
	 expires/2,
         apply_read_mask/1,
         pretty_print/2]).

%% @type context() = term()
-record(ctx, {bucket,       %% atom() - Bucket name (from uri)
              key,          %% binary()|container - Key (or sentinal
                            %%   meaning "no key provided")
              jiak_context, %% jiak_context() - context for the request
              jiak_name,    %% string() - prefix for jiak uris
              jiak_client,  %% jiak_client() - the store client
              etag,         %% string() - ETag header
              bucketkeys,   %% [binary()] - keys in the bucket
              diffs,        %% {[object_diff()],{AddedLinks::[jiak_link()],
                            %%                   RemovedLinks::[jiak_link()]}
              incoming,     %% jiak_object() - object the client is storing
              storedobj}).  %% jiak_object() - object stored in Riak

-include_lib("webmachine/include/webmachine.hrl").

%% @type key() = container|riak_object:binary_key()

%% @spec init(proplist()) -> {ok, context()}
%% @doc Initialize this webmachine resource.  This function will
%%      attempt to open a client to Riak, and will fail if it is
%%      unable to do so.
init(Props) ->
    {ok, JiakClient} = 
        case proplists:get_value(riak_local, Props) of
            true ->
                jiak:local_client();
            _ ->
                jiak:client_connect(
                  proplists:get_value(riak_ip, Props),
                  proplists:get_value(riak_port, Props),
                  proplists:get_value(riak_cookie, Props))
        end,
    {ok, #ctx{jiak_name=proplists:get_value(jiak_name, Props),
              key=proplists:get_value(key_type, Props),
              jiak_client=JiakClient}}.

%% @spec allowed_methods(webmachine:wrq(), context()) ->
%%          {[http_method()], webmachine:wrq(), context()}
%% @type http_method() = 'HEAD'|'GET'|'POST'|'PUT'|'DELETE'
%% @doc Determine the list of HTTP methods that can be used on this
%%      resource.  Should be HEAD/GET/POST for buckets and
%%      HEAD/GET/POST/PUT/DELETE for objects.
%%      Exception: HEAD/GET is returned for an "unknown" bucket.
allowed_methods(RD, Ctx0) ->
    Key = case Ctx0#ctx.key of
              container -> container;
              _         -> list_to_binary(wrq:path_info(key, RD))
          end,
    case bucket_from_uri(RD) of
        {ok, Bucket} ->
            {ok, JC} = Bucket:init(Key, jiak_context:new(not_diffed_yet, [])),
            Ctx = Ctx0#ctx{bucket=Bucket, key=Key, jiak_context=JC},
            case Key of
                container ->
                    %% buckets have GET for list_keys, POST for create
                    {['HEAD', 'GET', 'POST'], RD, Ctx};
                _ ->
                    %% keys have the "full" doc store set
                    {['HEAD', 'GET', 'POST', 'PUT', 'DELETE'], RD, Ctx}
            end;
        {error, no_such_bucket} ->
            %% no bucket, nothing but GET/HEAD allowed
            {['HEAD', 'GET'], RD, Ctx0#ctx{bucket={error, no_such_bucket}}}
    end.

%% @spec bucket_from_uri(webmachine:wrq()) ->
%%         {ok, atom()}|{error, no_such_bucket}
%% @doc Extract the bucket name, as an atom, from the request URI.
%%      The bucket name must be an existing atom, or this function
%%      will return {error, no_such_bucket}
bucket_from_uri(RD) ->
    try {ok, list_to_existing_atom(wrq:path_info(bucket, RD))}
    catch _:_ -> {error, no_such_bucket} end.

%% @spec malformed_request(webmachine:wrq(), context()) ->
%%          {boolean(), webmachine:wrq(), context()}
%% @doc Determine whether the request is propertly constructed.
%%      GET is always properly constructed
%%      PUT/POST is malformed if:
%%        - request body is not a valid JSON object
%%        - the object contains a link to a bucket that is
%%          "unknown" (non-existent atom)
%%      PUT is malformed if:
%%        - the "bucket" field of the object does not match the
%%          bucket component of the URI
%%        - the "key" field of the object does not match the
%%          key component of the URI
malformed_request(ReqData, Context=#ctx{bucket=Bucket,key=Key}) ->
    % just testing syntax and required fields on POST and PUT
    % also, bind the incoming body here
    case lists:member(wrq:method(ReqData), ['POST', 'PUT']) of
        false -> {false, ReqData, Context};
        true ->
            case decode_object(wrq:req_body(ReqData)) of
                {ok, JiakObject0={struct,_}} ->
                    case atomify_buckets(JiakObject0) of
                        {ok, JiakObject} ->
                            PT = wrq:method(ReqData) == 'PUT',
                            KM = jiak_object:key(JiakObject) == Key,
                            BM = jiak_object:bucket(JiakObject) == Bucket,
                            if (not PT); (PT andalso KM andalso BM) ->
                                    {false, ReqData, Context#ctx{incoming=JiakObject}};
                               not KM ->
                                    {true,
                                     wrq:append_to_response_body("Object key does not match URI",
                                                                 ReqData),
                                     Context};
                               not BM ->
                                    {true,
                                     wrq:append_to_response_body("Object bucket does not match URI",
                                                                 ReqData),
                                     Context}
                            end;
                        _ ->
                            {true,
                             wrq:append_to_response_body("Unknown bucket in link.",
                                                         ReqData),
                             Context}
                    end;
                _ ->
                    {true,
                     wrq:append_to_response_body("Poorly formed JSON Body.",
                                                 ReqData),
                     Context}
            end
    end.

%% @spec decode_object(iolist()) -> {ok, mochijson2()}|{error, bad_json}
%% @doc Wrap up mochijson2:decode/1 so the process doesn't die if
%%      decode fails.
decode_object(Body) ->
    try {ok, mochijson2:decode(Body)}
    catch _:_ -> {error, bad_json} end.

%% @spec atomify_buckets(mochijson2()) ->
%%         {ok, mochijson2()}|{error, no_such_bucket}
%% @doc Convert binary() bucket names into atom() bucket names in the
%%      "bucket" and "links" fields.  This is necessary because
%%      mochijson2:encode/1 converts Erlang atoms to JSON strings, but
%%      mochijson2:decode/1 converts JSON strings to Erlange binaries.
atomify_buckets({struct,JOProps}) ->
    try
        BinBucket = proplists:get_value(<<"bucket">>, JOProps),
        Bucket = list_to_existing_atom(binary_to_list(BinBucket)),
        BinLinks = proplists:get_value(<<"links">>, JOProps),
        Links = [ [list_to_existing_atom(binary_to_list(B)), K, T] || [B,K,T] <- BinLinks],
        {ok, {struct, [{<<"bucket">>, Bucket},
                       {<<"links">>, Links}
                       |[{K,V} || {K,V} <- JOProps,
                                  K /= <<"bucket">>, K /= <<"links">>]]}}
    catch _:_ -> {error, no_such_bucket} end.

%% @spec check_required(jiak_object(), [binary()]) -> boolean()
%% @doc Determine whether Obj contains all of the fields named in
%%      the Fields parameter.  Returns 'true' if all Fields are
%%      present in Obj, 'false' otherwise.
check_required(Obj, Fields) ->
    Required = sets:from_list(Fields),
    Has = sets:from_list(jiak_object:props(Obj)),
    sets:is_subset(Required, Has).

%% @spec check_allowed(jiak_object(), [binary()]) -> boolean()
%% @doc Determine whether Obj contains any fields not named in the
%%      Fields parameter.  Returns 'true' if Obj contains only
%%      fields named by Fields, 'false' if Obj contains any fields
%%      not named in Fields.
check_allowed(Obj, Fields) ->
    Allowed = sets:from_list(Fields),
    Has = sets:from_list(jiak_object:props(Obj)),
    sets:is_subset(Has, Allowed).

%% @spec check_write_mask(riak_object:bucket(), diff()) -> boolean()
%% @doc Determine whether any fields outside the write mask of the
%%      bucket have been modified.  Returns 'true' if only fields in
%%      the bucket's write mask were modified, 'false' otherwise.
check_write_mask(Mod, {PropDiffs,_}) ->
    WriteMask = Mod:write_mask(),
    %% XXX should probably use a special atom like 'JAPI_UNDEFINED' for
    %% non-existant keys produced by the diff.
    [{Key, OldVal} || {Key, OldVal, _NewVal} <- PropDiffs,
		      lists:member(Key, WriteMask) =:= false] =:= [].

%% @spec is_authorized(webmachine:wrq(), context()) ->
%%          {true|string(), webmachine:wrq(), context()}
%% @doc Determine whether the request is authorized.  This function
%%      calls through to the bucket's auth_ok/3 function.
is_authorized(ReqData, Context=#ctx{bucket={error, no_such_bucket}}) ->
    {{halt, 404},
     wrq:append_to_response_body("Unknown bucket.", ReqData),
     Context};
is_authorized(ReqData, Context=#ctx{key=Key,bucket=Bucket,jiak_context=JC}) ->
    {Result, RD1, JC1} = Bucket:auth_ok(Key, ReqData, JC),
    {Result, RD1, Context#ctx{jiak_context=JC1}}.

%% @spec forbidden(webmachine:wrq(), context()) ->
%%          {boolean(), webmachine:wrq(), context()}
%% @doc For an object GET/PUT/POST or a bucket POST, check to see
%%      whether the write request violates the write mask of the
%%      bucket.  For a bucket GET, check to see whether the keys of
%%      the bucket are listable.
forbidden(ReqData, Context=#ctx{bucket=Bucket,key=container}) ->
    case wrq:method(ReqData) of
        'POST' -> object_forbidden(ReqData, Context);
        _      -> {not Bucket:bucket_listable(), ReqData, Context}
    end;
forbidden(ReqData, Context) ->
    case lists:member(wrq:method(ReqData), ['POST', 'PUT']) of
	true  -> object_forbidden(ReqData, Context);
	false -> {false, ReqData, Context}
    end.

%% @spec object_forbidden(webmachine:wrq(), context()) ->
%%         {boolean(), webmachine:wrq(), context()}
%% @doc Determine whether an object write violates the write mask of
%%      the bucket.
object_forbidden(ReqData, Context=#ctx{bucket=Bucket,jiak_context=JC}) ->
    {Diffs, NewContext0} = diff_objects(ReqData, Context),
    NewContext = NewContext0#ctx{jiak_context=JC:set_diff(Diffs)},
    Permitted = check_write_mask(Bucket, Diffs),    
    case Permitted of
        false ->
            {true,
             wrq:append_to_response_body(
               io_lib:format(
                 "Write disallowed, some of ~p not writable.~n", 
                 [[K || {K,_,_} <- element(1, Diffs)]]),
               ReqData),
             NewContext};
        true ->
            {false, ReqData, NewContext}
    end.

%% @spec encodings_provided(webmachine:wrq(), context()) ->
%%         {[encoding()], webmachine:wrq(), context()}
%% @doc Get the list of encodings this resource provides.
%%      "identity" is provided for all methods, and "gzip" is
%%      provided for GET as well
encodings_provided(ReqData, Context) ->
    case wrq:method(ReqData) of
        'GET' ->
            {[{"identity", fun(X) -> X end},
              {"gzip", fun(X) -> zlib:gzip(X) end}], ReqData, Context};
        _ ->
            {[{"identity", fun(X) -> X end}], ReqData, Context}
    end.

%% @spec resource_exists(webmachine:wrq(), context()) ->
%%          {boolean, webmachine:wrq(), context()}
%% @doc Determine whether or not the resource exists.
%%      This resource exists if the bucket is known or the object
%%      was successfully fetched from Riak.
resource_exists(ReqData, Context=#ctx{key=container}) ->
    %% bucket existence was tested in is_authorized
    {true, ReqData, Context};
resource_exists(ReqData, Context) ->
    case retrieve_object(ReqData, Context) of
        {notfound, Context1} -> {false, ReqData, Context1};
        {error, {Err, Context1}} -> {{error, Err}, ReqData, Context1};
        {ok, {_Obj, Context1}} -> {true, ReqData, Context1}
    end.

%% @spec content_types_provided(webmachine:wrq(), context()) ->
%%          {[ctype()], webmachine:wrq(), context()}
%% @doc Get the list of content types this resource provides.
%%      "application/json" and "text/plain" are both provided
%%      for all requests.  "text/plain" is a "pretty-printed"
%%      version of the "application/json" content.
content_types_provided(ReqData, Context) ->
    {[{"application/json", produce_body},
      {"text/plain", pretty_print}],
     ReqData, Context}.

%% @spec content_types_accepted(webmachine:wrq(), context()) ->
%%          {[ctype()], webmachine:wrq(), context()}
%% @doc Get the list of content types accepted by this resource.
%%      Only "application/json" is accepted.
content_types_accepted(ReqData, Context) ->
    {[{"application/json", handle_incoming}], ReqData, Context}.

%% @spec produce_body(webmachine:wrq(), context()) ->
%%          {io_list(), webmachine:wrq(), context()}
%% @doc Get the representation of this resource that will be
%%      sent to the client.
produce_body(ReqData, Context=#ctx{key=container,
                                   bucket=Bucket}) ->
    Qopts = wrq:req_qs(ReqData),
    Schema = case proplists:lookup("schema", Qopts) of
                 {"schema", "false"} -> [];
                 _ -> [{schema, {struct, full_schema(Bucket)}}]
             end,
    {Keys, Context1} = case proplists:lookup("keys", Qopts) of
                           {"keys", "false"} -> {[], Context};
                           _ -> 
                               {ok, {K, NewCtx}} = retrieve_keylist(Context),
                               {[{keys, K}], NewCtx}
                       end,
    JSONSpec = {struct, Schema ++ Keys},
    {mochijson2:encode(JSONSpec), ReqData, Context1};
produce_body(ReqData, Context=#ctx{}) ->
    {ok, {JiakObject0, Context1}} = retrieve_object(ReqData, Context),
    JiakObject = apply_read_mask(JiakObject0),
    {mochijson2:encode(JiakObject),
     wrq:set_resp_header("X-JIAK-VClock",
                         binary_to_list(jiak_object:vclock(JiakObject)),
                         ReqData),
     Context1}.    

%% @spec full_schema(riak_object:bucket()) ->
%%          [{schema_type(), [binary()]}]
%% @type schema_type() = allowed_fields |
%%                       required_fields |
%%                       read_mask |
%%                       write_mask
%% @doc Get the schema for the bucket.
full_schema(Bucket) ->
    [{allowed_fields, Bucket:allowed_fields()},
     {required_fields, Bucket:required_fields()},
     {read_mask, Bucket:read_mask()},
     {write_mask, Bucket:write_mask()}].

%% @spec make_uri(string(), riak_object:bucket(), string()) -> string()
%% @doc Get the string-path for the bucket and subpath under jiak.
make_uri(JiakName,Bucket,Path) ->
    "/" ++ JiakName ++ "/" ++ atom_to_list(Bucket) ++ "/" ++ Path.

%% @spec handle_incoming(webmachine:wrq(), context()) ->
%%          {true, webmachine:wrq(), context()}
%% @doc Handle POST/PUT requests.  This is where the actual Riak-put
%%      happens, as well as where the bucket's check_write,
%%      effect_write, and after_write functions are called.
handle_incoming(ReqData, Context=#ctx{bucket=Bucket,key=Key,
                                      jiak_context=JCTX,jiak_name=JiakName,
                                      jiak_client=JiakClient,
                                      incoming=JiakObject0})->
    {PutType, NewRD, ObjId} =
        case Key of
            container -> % POST to bucket has its fresh id in Path
                {container,
                 wrq:set_resp_header("Location",
                                     make_uri(JiakName,Bucket,
                                              wrq:disp_path(ReqData)),
                                     ReqData),
                 list_to_binary(wrq:disp_path(ReqData))};
            _ ->
                {item, ReqData, Key}
        end,
    case Bucket:check_write({PutType, ObjId},JiakObject0,NewRD,JCTX) of
        {{error, Reason}, RD1, JC1} ->
            {{halt,403},
             wrq:append_to_response_body(
               io_lib:format("Write disallowed, ~p.~n", [Reason]), RD1),
             Context#ctx{jiak_context=JC1}};
        {{ok, JiakObject1}, RD1, JC1} ->
	    Allowed = Bucket:allowed_fields(),
	    case check_allowed(JiakObject1, Allowed) of
		true ->
		    Required = Bucket:required_fields(),
		    case check_required(JiakObject1, Required) of
			true ->
			    case Bucket:effect_write(Key,JiakObject1,RD1,JC1) of
				{{error, Reason},RD2,JC2} ->
                                    {{error, Reason}, RD2,
                                     Context#ctx{jiak_context=JC2}};
				{{ok, JiakObject2}, RD2, JC2} ->
                                    JiakObjectWrite = if Key == container ->
                                                              jiak_object:setf(JiakObject2, <<"key">>, ObjId);
                                                         true ->
                                                              JiakObject2
                                                      end,
                                    W = integer_query("w", 2, ReqData),
                                    DW = integer_query("dw", 2, ReqData),
				    ok = JiakClient:put(JiakObjectWrite, W, DW),
                                    {ok, RD3, JC3} = Bucket:after_write(Key,JiakObject2,RD2,JC2),
                                    {RD4, Context1} =
                                        case proplists:lookup("returnbody", wrq:req_qs(RD1)) of
                                            {"returnbody", "true"} ->
                                                {Body, RD3a, Ctx1} =
                                                    produce_body(RD3,
                                                                 Context#ctx{
                                                                   storedobj=undefined,
                                                                   key=ObjId}),
                                                {wrq:append_to_response_body(Body, RD3a),
                                                 Ctx1#ctx{jiak_context=JC3}};
                                            _ -> {RD3, Context#ctx{jiak_context=JC3}}
                                        end,
				    {ok, RD4, Context1#ctx{incoming=JiakObject2}}
			    end;
			false ->
			    {{halt,403},
                             wrq:append_to_response_body(
                               "Missing Required Field.", RD1),
                             Context#ctx{jiak_context=JC1}}
		    end;
		false ->
		    {{halt, 403},
                     wrq:append_to_response_body(
                       "Invalid fields in request", RD1),
                     Context#ctx{jiak_context=JC1}}
            end
    end.

%% @spec post_is_create(webmachine:wrq(), context()) ->
%%          {true, webmachine:wrq(), context()}
%% @doc POST is always "create" here.  We'll make a path and
%%      handle it as a PUT to that path.
post_is_create(ReqData, Context) ->
    {true, ReqData, Context}.

%% @spec create_path(webmachine:wrq(), context()) ->
%%          {string(), webmachine:wrq(), context()}
%% @doc Create a path for converting a POST request to a PUT.  The
%%      returned path will be a fresh server-generated path in the
%%      case of a POST to a bucket, or the path for the given object
%%      in the case of a POST to a specific object.
create_path(ReqData, Context=#ctx{key=container}) ->
    {riak_util:unique_id_62(), ReqData, Context};
create_path(ReqData, Context=#ctx{key=Key}) ->
    {Key, ReqData, Context}.

%% @spec delete_resource(webmachine:wrq(), context()) ->
%%          {boolean(), webmachine:wrq(), context()}
%% @doc Delete the resource at the given Bucket and Key.
delete_resource(ReqData, Context=#ctx{bucket=Bucket,key=Key,
                                      jiak_client=JiakClient}) ->
    RW = integer_query("rw", 2, ReqData),
    {ok == JiakClient:delete(Bucket, Key, RW),
     ReqData, Context}.

%% @spec generate_etag(webmachine:wrq(), context()) ->
%%          {string(), webmachine:wrq(), context()}
%% @doc Generate an ETag for this resource.
generate_etag(ReqData, Context=#ctx{key=container,etag=undefined}) ->
    make_bucket_etag(ReqData, Context);
generate_etag(ReqData, Context=#ctx{etag=undefined}) ->
    make_object_etag(ReqData, Context);
generate_etag(_, #ctx{etag=ETag}) -> ETag.

%% @spec make_bucket_etag(webmachine:wrq(), context()) ->
%%          {string(), webmachine:wrq(), context()}
%% @doc Generate the ETag for a bucket.
make_bucket_etag(ReqData, Context) ->
    {ok, {Keys, Context1}} = retrieve_keylist(Context),
    ETag = mochihex:to_hex(crypto:sha(term_to_binary(Keys))),
    {ETag, ReqData, Context1#ctx{etag=ETag}}.

%% @spec retrieve_keylist(context()) -> {ok, {[binary()], context()}}
%% @doc Get the list of keys in this bucket.  This function
%%      memoizes the keylist in the context so it can be
%%      called multiple times without duplicating work.
retrieve_keylist(Context=#ctx{bucket=Bucket,jiak_client=JiakClient,
                              bucketkeys=undefined}) ->
    {ok, Keys} = JiakClient:list_keys(Bucket),
    {ok, {Keys, Context#ctx{bucketkeys=Keys}}};
retrieve_keylist(Context=#ctx{bucketkeys=Keys}) ->
    {ok, {Keys, Context}}.

%% @spec make_object_etag(webmachine:wrq(), context()) ->
%%          {string(), webmachine:wrq(), context()}
%% @doc Generate the ETag for an object.
make_object_etag(ReqData, Context=#ctx{}) ->
    {ok, {JiakObject, Context1}} = retrieve_object(ReqData, Context),
    ETag = binary_to_list(jiak_object:vtag(JiakObject)),
    {ETag, ReqData, Context1#ctx{etag=ETag}}.

%% @spec retrieve_object(webmachine:wrq(), context()) ->
%%          {ok, {jiak_object(), context()}}
%% @doc Fetch the requested object from Riak.  This function
%%      memoizes the object in the context so it can be
%%      called multiple times without duplicating work.
retrieve_object(ReqData, Context=#ctx{bucket=Bucket,key=Key,
                                      storedobj=undefined,
                                      jiak_client=JiakClient}) ->
    R = integer_query("r", 2, ReqData),
    case JiakClient:get(Bucket, Key, R) of
        {error, notfound} -> 
            {notfound, Context};
        {error, Err} ->
            {error, {Err, Context}};
        {ok, Obj} ->
            {ok, {Obj, Context#ctx{storedobj=Obj}}}
    end;
retrieve_object(_ReqData, Context=#ctx{storedobj=StoredObj}) ->
    {ok, {StoredObj, Context}}.

%% @spec last_modified(webmachine:wrq(), context()) ->
%%          {datetime(), webmachine:wrq(), context()}
%% @doc Get the last-modified time for this resource.  Bucket keylists
%%      are said to have been last-modified "now".
last_modified(ReqData, Context=#ctx{storedobj=JiakObject,
                                    key=Key}) when Key /= container ->
    {httpd_util:convert_request_date(
       binary_to_list(jiak_object:lastmod(JiakObject))), ReqData, Context};
last_modified(ReqData, Context) ->
    {erlang:universaltime(), ReqData, Context}.

%% @spec expires(webmachine:wrq(), context()) ->
%%          {datetime(), webmachine:wrq(), context()}
%% @doc Get the time at which a cache should expire its last fetch for
%%      this resource.  This function calls through to the bucket's
%%      expires_in_seconds/3 function.
expires(ReqData, Context=#ctx{key=Key, bucket=Bucket, jiak_context=JC}) ->
    {ExpiresInSecs, RD1, JC1} = Bucket:expires_in_seconds(Key, ReqData, JC),
    Now = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
    {calendar:gregorian_seconds_to_datetime(Now+ExpiresInSecs),
     RD1, Context#ctx{jiak_context=JC1}}.

%% @spec diff_objects(webmachine:wrq(), context()) -> {diff(), context()}
%% @type diff() = {object_diff(), links_diff()}
%% @doc Compare the incoming object to the last-known value of this
%%      object (or an empty object if the incoming is new) to determine
%5      the list of changes made by the client.  This function memoizes
%%      its result in the context so it can be called multiple times
%%      without duplicating work.
diff_objects(_ReqData, Context=#ctx{incoming=NewObj, key=container}) ->
    %% same as notfound
    Diffs = jiak_object:diff(undefined, NewObj),
    {Diffs, Context#ctx{diffs=Diffs}};
diff_objects(ReqData, Context=#ctx{incoming=NewObj0, bucket=Bucket}) ->
    case retrieve_object(ReqData, Context) of
	{notfound, NewContext} ->
	    Diffs = jiak_object:diff(undefined, NewObj0),
	    {Diffs, NewContext#ctx{diffs=Diffs}};
	{ok, {JiakObject, NewContext}} ->
	    NewObj = copy_unreadable_props(Bucket, JiakObject, NewObj0),
	    Diffs = jiak_object:diff(JiakObject, NewObj),
	    {Diffs, NewContext#ctx{diffs=Diffs, storedobj=NewObj, 
				   incoming=NewObj}}
    end.

%% @spec apply_read_mask(jiak_object()) -> jiak_object()
%% @doc Remove fields from the jiak object that are not in the
%%      bucket's read maks.
apply_read_mask(JiakObject={struct,_}) ->
    Module = jiak_object:bucket(JiakObject),
    {struct, OldData} = jiak_object:object(JiakObject),
    NewData = apply_read_mask1(OldData, Module:read_mask(), []),
    jiak_object:set_object(JiakObject, {struct, NewData}).

%% @private
apply_read_mask1([], _ReadMask, Acc) ->
    lists:reverse(Acc);
apply_read_mask1([{K,_V}=H|T], ReadMask, Acc) ->
    case lists:member(K, ReadMask) of
	true ->
	    apply_read_mask1(T, ReadMask, [H|Acc]);
	false ->
	    apply_read_mask1(T, ReadMask, Acc)
    end.

%% @spec copy_unreadable_props(riak_object:bucket(), jiak_object(),
%%                             jiak_object()) -> jiak_object()
%% @doc Copy fields that are not in the bucket's read mask from OldObj
%%      to NewObj.  This is necessary for computing client changes:
%%      since the client can't know the values of fields not in the
%%      read mask, it can't preserve their values, so we have to do it
%%      for them.
copy_unreadable_props(Bucket, OldObj, NewObj) ->
    Allowed = Bucket:allowed_fields(),
    ReadMask = Bucket:read_mask(),
    Unreadable = sets:to_list(sets:subtract(
				sets:from_list(Allowed),
				sets:from_list(ReadMask))),
    {struct, OldData} = jiak_object:object(OldObj),
    {struct, NewData} = jiak_object:object(NewObj),
    UnreadableData = copy_unreadable1(Unreadable, OldData, NewData),
    jiak_object:set_object(NewObj, {struct, UnreadableData}).

%% @private    
copy_unreadable1([], _OldObj, NewObj) ->
    NewObj;
copy_unreadable1([H|T], OldObj, NewObj) ->
    copy_unreadable1(T, OldObj,
                     case proplists:lookup(H, OldObj) of
                         {H, Val} -> [{H, Val}|NewObj];
                         none     -> NewObj
                     end).

%% @spec pretty_print(webmachine:wrq(), context()) ->
%%          {string(), webmachine:wrq(), context()}
%% @doc Format the respons JSON object is a "pretty-printed" style.
pretty_print(RD1, C1=#ctx{}) ->
    {Json, RD2, C2} = produce_body(RD1, C1),
    {json_pp:print(binary_to_list(list_to_binary(Json))), RD2, C2}.

integer_query(ParamName, Default, ReqData) ->
    case wrq:get_qs_value(ParamName, ReqData) of
        undefined -> Default;
        String    -> list_to_integer(String)
    end.
