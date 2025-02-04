{-# LANGUAGE DuplicateRecordFields #-}
{-|
Module      : PostgREST.Query.QueryBuilder
Description : PostgREST SQL queries generating functions.

This module provides functions to consume data types that
represent database queries (e.g. ReadRequest, MutateRequest) and SqlFragment
to produce SqlQuery type outputs.
-}
module PostgREST.Query.QueryBuilder
  ( readRequestToQuery
  , mutateRequestToQuery
  , readRequestToCountQuery
  , requestToCallProcQuery
  , limitedQuery
  ) where

import qualified Data.ByteString.Char8           as BS
import qualified Data.Set                        as S
import qualified Hasql.DynamicStatements.Snippet as SQL

import Data.Tree (Tree (..))

import PostgREST.DbStructure.Identifiers  (QualifiedIdentifier (..))
import PostgREST.DbStructure.Proc         (ProcParam (..))
import PostgREST.DbStructure.Relationship (Cardinality (..),
                                           Relationship (..))
import PostgREST.DbStructure.Table        (Table (..))
import PostgREST.Request.Preferences      (PreferResolution (..))

import PostgREST.Query.SqlFragment
import PostgREST.Request.Types

import Protolude

readRequestToQuery :: ReadRequest -> SQL.Snippet
readRequestToQuery (Node (Select colSelects mainQi tblAlias implJoins logicForest joinConditions_ ordts range, _) forest) =
  "SELECT " <>
  intercalateSnippet ", " ((pgFmtSelectItem qi <$> colSelects) ++ selects) <>
  "FROM " <> SQL.sql (BS.intercalate ", " (tabl : implJs)) <> " " <>
  intercalateSnippet " " joins <> " " <>
  (if null logicForest && null joinConditions_ then mempty else "WHERE " <> intercalateSnippet " AND " (map (pgFmtLogicTree qi) logicForest ++ map pgFmtJoinCondition joinConditions_))
  <> " " <>
  (if null ordts then mempty else "ORDER BY " <> intercalateSnippet ", " (map (pgFmtOrderTerm qi) ordts)) <> " " <>
  limitOffsetF range
  where
    implJs = fromQi <$> implJoins
    tabl = fromQi mainQi <> maybe mempty (\a -> " AS " <> pgFmtIdent a) tblAlias
    qi = maybe mainQi (QualifiedIdentifier mempty) tblAlias
    (joins, selects) = foldr getJoinsSelects ([],[]) forest

getJoinsSelects :: ReadRequest -> ([SQL.Snippet], [SQL.Snippet]) -> ([SQL.Snippet], [SQL.Snippet])
getJoinsSelects rr@(Node (_, (name, Just Relationship{relCardinality=card,relTable=Table{tableName=table}}, alias, _, joinType, _)) _) (joins,selects) =
  let subquery = readRequestToQuery rr in
  case card of
    M2O _ ->
      let aliasOrName = fromMaybe name alias
          localTableName = pgFmtIdent $ table <> "_" <> aliasOrName
          sel = SQL.sql ("row_to_json(" <> localTableName <> ".*) AS " <> pgFmtIdent aliasOrName)
          joi = (if joinType == Just JTInner then " INNER" else " LEFT")
            <> " JOIN LATERAL( " <> subquery <> " ) AS " <> SQL.sql localTableName <> " ON TRUE " in
      (joi:joins,sel:selects)
    _ -> case joinType of
      Just JTInner ->
        let aliasOrName = fromMaybe name alias
            locTblName = table <> "_" <> aliasOrName
            localTableName = pgFmtIdent locTblName
            internalTableName = pgFmtIdent $ "_" <> locTblName
            sel = SQL.sql $ localTableName <> "." <> internalTableName <> " AS " <> pgFmtIdent aliasOrName
            joi = "INNER JOIN LATERAL(" <>
                    "SELECT json_agg(" <> SQL.sql internalTableName <> ") AS " <> SQL.sql internalTableName <>
                    "FROM (" <> subquery <> " ) AS " <> SQL.sql internalTableName <>
                  ") AS " <> SQL.sql localTableName <> " ON " <> SQL.sql localTableName <> "IS NOT NULL" in
        (joi:joins,sel:selects)
      _ ->
        let sel = "COALESCE (("
               <> "SELECT json_agg(" <> SQL.sql (pgFmtIdent table) <> ".*) "
               <> "FROM (" <> subquery <> ") " <> SQL.sql (pgFmtIdent table) <> " "
               <> "), '[]') AS " <> SQL.sql (pgFmtIdent (fromMaybe name alias)) in
        (joins,sel:selects)
getJoinsSelects (Node (_, (_, Nothing, _, _, _, _)) _) _ = ([], [])

mutateRequestToQuery :: MutateRequest -> SQL.Snippet
mutateRequestToQuery (Insert mainQi iCols body onConflct putConditions returnings) =
  "WITH " <> normalizedBody body <> " " <>
  "INSERT INTO " <> SQL.sql (fromQi mainQi) <> SQL.sql (if S.null iCols then " " else "(" <> cols <> ") ") <>
  "SELECT " <> SQL.sql cols <> " " <>
  SQL.sql ("FROM json_populate_recordset (null::" <> fromQi mainQi <> ", " <> selectBody <> ") _ ") <>
  -- Only used for PUT
  (if null putConditions then mempty else "WHERE " <> intercalateSnippet " AND " (pgFmtLogicTree (QualifiedIdentifier mempty "_") <$> putConditions)) <>
  SQL.sql (BS.unwords [
    maybe "" (\(oncDo, oncCols) ->
      if null oncCols then
        mempty
      else
        "ON CONFLICT(" <> BS.intercalate ", " (pgFmtIdent <$> oncCols) <> ") " <> case oncDo of
        IgnoreDuplicates ->
          "DO NOTHING"
        MergeDuplicates  ->
          if S.null iCols
             then "DO NOTHING"
             else "DO UPDATE SET " <> BS.intercalate ", " (pgFmtIdent <> const " = EXCLUDED." <> pgFmtIdent <$> S.toList iCols)
      ) onConflct,
    returningF mainQi returnings
    ])
  where
    cols = BS.intercalate ", " $ pgFmtIdent <$> S.toList iCols
mutateRequestToQuery (Update mainQi uCols body logicForest returnings) =
  if S.null uCols
    -- if there are no columns we cannot do UPDATE table SET {empty}, it'd be invalid syntax
    -- selecting an empty resultset from mainQi gives us the column names to prevent errors when using &select=
    -- the select has to be based on "returnings" to make computed overloaded functions not throw
    then SQL.sql ("SELECT " <> emptyBodyReturnedColumns <> " FROM " <> fromQi mainQi <> " WHERE false")
    else
      "WITH " <> normalizedBody body <> " " <>
      "UPDATE " <> SQL.sql (fromQi mainQi) <> " SET " <> SQL.sql cols <> " " <>
      "FROM (SELECT * FROM json_populate_recordset (null::" <> SQL.sql (fromQi mainQi) <> " , " <> SQL.sql selectBody <> " )) _ " <>
      (if null logicForest then mempty else "WHERE " <> intercalateSnippet " AND " (pgFmtLogicTree mainQi <$> logicForest)) <> " " <>
      SQL.sql (returningF mainQi returnings)
  where
    cols = BS.intercalate ", " (pgFmtIdent <> const " = _." <> pgFmtIdent <$> S.toList uCols)
    emptyBodyReturnedColumns :: SqlFragment
    emptyBodyReturnedColumns
      | null returnings = "NULL"
      | otherwise       = BS.intercalate ", " (pgFmtColumn (QualifiedIdentifier mempty $ qiName mainQi) <$> returnings)
mutateRequestToQuery (Delete mainQi logicForest returnings) =
  "DELETE FROM " <> SQL.sql (fromQi mainQi) <> " " <>
  (if null logicForest then mempty else "WHERE " <> intercalateSnippet " AND " (map (pgFmtLogicTree mainQi) logicForest)) <> " " <>
  SQL.sql (returningF mainQi returnings)

requestToCallProcQuery :: CallRequest -> SQL.Snippet
requestToCallProcQuery (FunctionCall qi params args returnsScalar multipleCall returnings) =
  prmsCTE <> argsBody
  where
    (prmsCTE, argFrag) = case params of
      OnePosParam prm -> ("WITH pgrst_args AS (SELECT NULL)", singleParameter args (encodeUtf8 $ ppType prm))
      KeyParams []    -> (mempty, mempty)
      KeyParams prms  -> (
          "WITH " <> normalizedBody args <> ", " <>
          SQL.sql (
            BS.unwords [
            "pgrst_args AS (",
              "SELECT * FROM json_to_recordset(" <> selectBody <> ") AS _(" <> fmtParams prms (const mempty) (\a -> " " <> encodeUtf8 (ppType a)) <> ")",
            ")"])
         , SQL.sql $ if multipleCall
             then fmtParams prms varadicPrefix (\a -> " := pgrst_args." <> pgFmtIdent (ppName a))
             else fmtParams prms varadicPrefix (\a -> " := (SELECT " <> pgFmtIdent (ppName a) <> " FROM pgrst_args LIMIT 1)")
        )

    fmtParams :: [ProcParam] -> (ProcParam -> SqlFragment) -> (ProcParam -> SqlFragment) -> SqlFragment
    fmtParams prms prmFragPre prmFragSuf = BS.intercalate ", "
      ((\a -> prmFragPre a <> pgFmtIdent (ppName a) <> prmFragSuf a) <$> prms)

    varadicPrefix :: ProcParam -> SqlFragment
    varadicPrefix a = if ppVar a then "VARIADIC " else mempty

    argsBody :: SQL.Snippet
    argsBody
      | multipleCall =
          if returnsScalar
            then "SELECT " <> callIt <> " AS pgrst_scalar FROM pgrst_args"
            else "SELECT pgrst_lat_args.* FROM pgrst_args, " <>
                 "LATERAL ( SELECT " <> returnedColumns <> " FROM " <> callIt <> " ) pgrst_lat_args"
      | otherwise =
          if returnsScalar
            then "SELECT " <> callIt <> " AS pgrst_scalar"
            else "SELECT " <> returnedColumns <> " FROM " <> callIt

    callIt :: SQL.Snippet
    callIt = SQL.sql (fromQi qi) <> "(" <> argFrag <> ")"

    returnedColumns :: SQL.Snippet
    returnedColumns
      | null returnings = "*"
      | otherwise       = SQL.sql $ BS.intercalate ", " (pgFmtColumn (QualifiedIdentifier mempty $ qiName qi) <$> returnings)


-- | SQL query meant for COUNTing the root node of the Tree.
-- It only takes WHERE into account and doesn't include LIMIT/OFFSET because it would reduce the COUNT.
-- SELECT 1 is done instead of SELECT * to prevent doing expensive operations(like functions based on the columns)
-- inside the FROM target.
readRequestToCountQuery :: ReadRequest -> SQL.Snippet
readRequestToCountQuery (Node (Select{from=qi, where_=logicForest}, _) _) =
 "SELECT 1 " <> "FROM " <> SQL.sql (fromQi qi) <> " " <>
 if null logicForest then mempty else "WHERE " <> intercalateSnippet " AND " (map (pgFmtLogicTree qi) logicForest)

limitedQuery :: SQL.Snippet -> Maybe Integer -> SQL.Snippet
limitedQuery query maxRows = query <> SQL.sql (maybe mempty (\x -> " LIMIT " <> BS.pack (show x)) maxRows)
