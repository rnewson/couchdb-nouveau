% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_replicator_many_leaves_tests).

-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").

-import(couch_replicator_test_helper, [
    db_url/1,
    replicate/2
]).

-define(DOCS_CONFLICTS, [
    {<<"doc1">>, 10},
    % use some _design docs as well to test the special handling for them
    {<<"_design/doc2">>, 100},
    % a number > MaxURLlength (7000) / length(DocRevisionString)
    {<<"doc3">>, 210}
]).
-define(NUM_ATTS, 2).
-define(TIMEOUT_EUNIT, 60).
-define(i2l(I), integer_to_list(I)).
-define(io2b(Io), iolist_to_binary(Io)).

setup() ->
    DbName = ?tempdb(),
    {ok, Db} = couch_db:create(DbName, [?ADMIN_CTX]),
    ok = couch_db:close(Db),
    DbName.

setup(remote) ->
    {remote, setup()};
setup({A, B}) ->
    Ctx = test_util:start_couch([couch_replicator]),
    Source = setup(A),
    Target = setup(B),
    {Ctx, {Source, Target}}.

teardown({remote, DbName}) ->
    teardown(DbName);
teardown(DbName) ->
    ok = couch_server:delete(DbName, [?ADMIN_CTX]),
    ok.

teardown(_, {Ctx, {Source, Target}}) ->
    teardown(Source),
    teardown(Target),
    ok = application:stop(couch_replicator),
    ok = test_util:stop_couch(Ctx).

docs_with_many_leaves_test_() ->
    Pairs = [{remote, remote}],
    {
        "Replicate documents with many leaves",
        {
            foreachx,
            fun setup/1,
            fun teardown/2,
            [
                {Pair, fun should_populate_replicate_compact/2}
             || Pair <- Pairs
            ]
        }
    }.

should_populate_replicate_compact({From, To}, {_Ctx, {Source, Target}}) ->
    {
        lists:flatten(io_lib:format("~p -> ~p", [From, To])),
        {inorder, [
            should_populate_source(Source),
            should_replicate(Source, Target),
            should_verify_target(Source, Target),
            should_add_attachments_to_source(Source),
            should_replicate(Source, Target),
            should_verify_target(Source, Target)
        ]}
    }.

should_populate_source({remote, Source}) ->
    should_populate_source(Source);
should_populate_source(Source) ->
    {timeout, ?TIMEOUT_EUNIT, ?_test(populate_db(Source))}.

should_replicate({remote, Source}, Target) ->
    should_replicate(db_url(Source), Target);
should_replicate(Source, {remote, Target}) ->
    should_replicate(Source, db_url(Target));
should_replicate(Source, Target) ->
    {timeout, ?TIMEOUT_EUNIT, ?_test(replicate(Source, Target))}.

should_verify_target({remote, Source}, Target) ->
    should_verify_target(Source, Target);
should_verify_target(Source, {remote, Target}) ->
    should_verify_target(Source, Target);
should_verify_target(Source, Target) ->
    {timeout, ?TIMEOUT_EUNIT,
        ?_test(begin
            {ok, SourceDb} = couch_db:open_int(Source, []),
            {ok, TargetDb} = couch_db:open_int(Target, []),
            verify_target(SourceDb, TargetDb, ?DOCS_CONFLICTS),
            ok = couch_db:close(SourceDb),
            ok = couch_db:close(TargetDb)
        end)}.

should_add_attachments_to_source({remote, Source}) ->
    should_add_attachments_to_source(Source);
should_add_attachments_to_source(Source) ->
    {timeout, ?TIMEOUT_EUNIT,
        ?_test(begin
            {ok, SourceDb} = couch_db:open_int(Source, [?ADMIN_CTX]),
            add_attachments(SourceDb, ?NUM_ATTS, ?DOCS_CONFLICTS),
            ok = couch_db:close(SourceDb)
        end)}.

populate_db(DbName) ->
    {ok, Db} = couch_db:open_int(DbName, [?ADMIN_CTX]),
    lists:foreach(
        fun({DocId, NumConflicts}) ->
            Value = <<"0">>,
            Doc = #doc{
                id = DocId,
                body = {[{<<"value">>, Value}]}
            },
            {ok, _} = couch_db:update_doc(Db, Doc, [?ADMIN_CTX]),
            {ok, _} = add_doc_siblings(Db, DocId, NumConflicts)
        end,
        ?DOCS_CONFLICTS
    ),
    couch_db:close(Db).

add_doc_siblings(Db, DocId, NumLeaves) when NumLeaves > 0 ->
    add_doc_siblings(Db, DocId, NumLeaves, [], []).

add_doc_siblings(Db, _DocId, 0, AccDocs, AccRevs) ->
    {ok, []} = couch_db:update_docs(Db, AccDocs, [], replicated_changes),
    {ok, AccRevs};
add_doc_siblings(Db, DocId, NumLeaves, AccDocs, AccRevs) ->
    Value = ?l2b(?i2l(NumLeaves)),
    Rev = couch_hash:md5_hash(Value),
    Doc = #doc{
        id = DocId,
        revs = {1, [Rev]},
        body = {[{<<"value">>, Value}]}
    },
    add_doc_siblings(
        Db,
        DocId,
        NumLeaves - 1,
        [Doc | AccDocs],
        [{1, Rev} | AccRevs]
    ).

verify_target(_SourceDb, _TargetDb, []) ->
    ok;
verify_target(SourceDb, TargetDb, [{DocId, NumConflicts} | Rest]) ->
    {ok, SourceLookups} = couch_db:open_doc_revs(
        SourceDb,
        DocId,
        all,
        [conflicts, deleted_conflicts]
    ),
    {ok, TargetLookups} = couch_db:open_doc_revs(
        TargetDb,
        DocId,
        all,
        [conflicts, deleted_conflicts]
    ),
    SourceDocs = [Doc || {ok, Doc} <- SourceLookups],
    TargetDocs = [Doc || {ok, Doc} <- TargetLookups],
    Total = NumConflicts + 1,
    ?assertEqual(Total, length(TargetDocs)),
    lists:foreach(
        fun({SourceDoc, TargetDoc}) ->
            SourceJson = couch_doc:to_json_obj(SourceDoc, [attachments]),
            TargetJson = couch_doc:to_json_obj(TargetDoc, [attachments]),
            ?assertEqual(SourceJson, TargetJson)
        end,
        lists:zip(SourceDocs, TargetDocs)
    ),
    verify_target(SourceDb, TargetDb, Rest).

add_attachments(_SourceDb, _NumAtts, []) ->
    ok;
add_attachments(SourceDb, NumAtts, [{DocId, NumConflicts} | Rest]) ->
    {ok, SourceLookups} = couch_db:open_doc_revs(SourceDb, DocId, all, []),
    SourceDocs = [Doc || {ok, Doc} <- SourceLookups],
    Total = NumConflicts + 1,
    ?assertEqual(Total, length(SourceDocs)),
    NewDocs = lists:foldl(
        fun(#doc{atts = Atts, revs = {Pos, [Rev | _]}} = Doc, Acc) ->
            NewAtts = lists:foldl(
                fun(I, AttAcc) ->
                    AttData = crypto:strong_rand_bytes(100),
                    NewAtt = couch_att:new([
                        {name,
                            ?io2b([
                                "att_",
                                ?i2l(I),
                                "_",
                                couch_doc:rev_to_str({Pos, Rev})
                            ])},
                        {type, <<"application/foobar">>},
                        {att_len, byte_size(AttData)},
                        {data, AttData}
                    ]),
                    [NewAtt | AttAcc]
                end,
                [],
                lists:seq(1, NumAtts)
            ),
            [Doc#doc{atts = Atts ++ NewAtts} | Acc]
        end,
        [],
        SourceDocs
    ),
    {ok, UpdateResults} = couch_db:update_docs(SourceDb, NewDocs, []),
    NewRevs = [R || {ok, R} <- UpdateResults],
    ?assertEqual(length(NewDocs), length(NewRevs)),
    add_attachments(SourceDb, NumAtts, Rest).
