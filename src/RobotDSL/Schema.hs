{-# LANGUAGE OverloadedStrings #-}
-- | A small JSON Schema (draft 2020-12) validator, used to check emitted
-- messages against the official VDA 5050 v3.0.0 schemas.
--
-- This implements the keyword subset the eight vendored schemas actually use:
-- @type@, @required@, @properties@, @items@, @enum@, @const@, @minimum@,
-- @maximum@, @exclusiveMinimum@, @minItems@, @allOf@, @if@/@then@/@else@,
-- @$ref@ (local, @#\/definitions\/...@ only) and @format@ (date-time only).
--
-- Everything else in those files — @title@, @description@, @examples@,
-- @unit@, @subtopic@, @$schema@ — is an annotation and is ignored.
--
-- @\$ref@ is resolved against the root document, which is all the VDA schemas
-- need: every reference in them is local.
module RobotDSL.Schema
  ( ValidationError(..)
  , SchemaError(..)
  , loadSchema
  , validate
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value(..))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import Data.Scientific (isInteger, toRealFloat)
import qualified Data.Vector as V
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Char as C

-- | A single schema violation, located by a JSON Pointer into the instance.
data ValidationError = ValidationError
  { vePath    :: !Text
  , veMessage :: !Text
  } deriving (Eq, Show)

-- | Failure to load or parse a schema document.
data SchemaError
  = SchemaReadError !FilePath !String
  | SchemaParseError !FilePath !String
  deriving (Eq, Show)

-- | Read and JSON-parse a schema document.
loadSchema :: FilePath -> IO (Either SchemaError Value)
loadSchema path = do
  r <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
  pure $ case r of
    Left e   -> Left (SchemaReadError path (show e))
    Right bs -> first (SchemaParseError path) (Data.Aeson.eitherDecodeStrict bs)

-- | Validate an instance against a schema document. For the VDA schemas the
-- root document is itself the schema, so the same value is passed twice.
validate :: Value -> Value -> [ValidationError]
validate schema instance_ = validateAgainst schema schema instance_

-- | Validate @instance@ against @root@ (the schema document itself).
--
-- Returns every violation found; an empty list means the instance conforms.
validateAgainst :: Value -> Value -> Value -> [ValidationError]
validateAgainst root schema instance_ = go root schema instance_ []
  where
    go :: Value -> Value -> Value -> [Text] -> [ValidationError]
    go rt sch inst path = case sch of
      Object o -> concat
        [ refErrors       rt o inst path
        , typeErrors         o inst path
        , enumErrors         o inst path
        , constErrors        o inst path
        , numericErrors      o inst path
        , arrayErrors     rt o inst path
        , objectErrors    rt o inst path
        , allOfErrors     rt o inst path
        , conditionalErr rt o inst path
        , formatErrors       o inst path
        ]
      -- JSON Schema also permits boolean schemas; neither is used here.
      Bool True  -> []
      Bool False -> err path "schema is false: nothing validates"
      _          -> []

    err p msg = [ValidationError (renderPath p) msg]

    at p msg = ValidationError (renderPath p) msg

-- ---------------------------------------------------------------------------
-- Keywords
-- ---------------------------------------------------------------------------

    refErrors :: Value -> KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    refErrors rt o inst path =
      case KM.lookup "$ref" o of
        Just (String target) -> case resolveRef rt target of
          Just targetSchema -> go rt targetSchema inst path
          Nothing ->
            [ValidationError (renderPath path)
              ("unresolvable $ref: " <> target)]
        _ -> []

    typeErrors :: KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    typeErrors o inst path =
      case KM.lookup "type" o of
        Just (String t) -> check [String t]
        Just (Array ts) -> check (V.toList ts)
        _               -> []
      where
        check ts
          | any (matches inst) ts = []
          | otherwise = [ValidationError (renderPath path)
              ("expected type " <> T.pack (show ts)
                <> ", got " <> T.pack (jsonTypeOf inst))]

    -- | A JSON @type@ test. @integer@ is stricter than @number@: the value
    -- must have no fractional part.
    matches :: Value -> Value -> Bool
    matches inst (String t)
      | t == "integer" = isJsonInteger inst
      | otherwise      = jsonTypeOf inst == T.unpack t
    matches _ _ = False

    isJsonInteger :: Value -> Bool
    isJsonInteger (Number n) = isInteger n
    isJsonInteger _         = False

    jsonTypeOf :: Value -> String
    jsonTypeOf v = case v of
      Object{} -> "object"
      Array{}  -> "array"
      String{} -> "string"
      Number{} -> "number"
      Bool{}   -> "boolean"
      Null     -> "null"

    enumErrors :: KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    enumErrors o inst path =
      case KM.lookup "enum" o of
        Just (Array allowed)
          | any (== inst) (V.toList allowed) -> []
          | otherwise -> [ValidationError (renderPath path)
              ("value is not one of " <> T.pack (show (V.toList allowed)))]
        _ -> []

    constErrors :: KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    constErrors o inst path =
      case KM.lookup "const" o of
        Just expected
          | expected == inst -> []
          | otherwise -> [ValidationError (renderPath path)
              ("expected constant " <> T.pack (show expected)
                <> ", got " <> T.pack (show inst))]
        _ -> []

    numericErrors :: KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    numericErrors o inst path = case inst of
      Number num ->
        let x = toRealFloat num :: Double
            -- @violates limit x@ is True when the instance breaks the bound.
            bound key violates = case KM.lookup key o of
              Just (Number limit)
                | violates x (toRealFloat limit) ->
                    [ValidationError (renderPath path)
                      (Key.toText key <> " violated: " <> T.pack (show x)
                        <> " vs limit " <> T.pack (show (toRealFloat limit :: Double)))]
              _ -> []
        in concat
             [ bound "minimum"          (<)   -- x <  minimum        is invalid
             , bound "maximum"          (>)   -- x >  maximum        is invalid
             , bound "exclusiveMinimum" (<=)  -- x <= exclusiveMin   is invalid
             ]
      _ -> []

    arrayErrors :: Value -> KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    arrayErrors rt o inst path = case inst of
      Array xs ->
        concat
          [ case KM.lookup "minItems" o of
              Just (Number n)
                | fromIntegral (V.length xs) < n ->
                    [ValidationError (renderPath path)
                      ("array has " <> T.pack (show (V.length xs))
                        <> " items, minItems is " <> T.pack (show n))]
              _ -> []
          , case KM.lookup "items" o of
              Just itemSchema ->
                concat (zipWith
                  (\i v -> go rt itemSchema v (path <> [T.pack (show (i :: Int))]))
                  [0 ..] (V.toList xs))
              _ -> []
          ]
      _ -> []

    objectErrors :: Value -> KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    objectErrors rt o inst path = case inst of
      Object obj ->
        concat
          [ case KM.lookup "required" o of
              Just (Array req) ->
                [ at (path ++ [k]) ("missing required property '" <> k <> "'")
                | String k <- V.toList req
                , not (KM.member (Key.fromText k) obj)
                ]
              _ -> []
          , case KM.lookup "properties" o of
              Just (Object props) ->
                concat
                  [ go rt propSchema val (path <> [Key.toText name])
                  | (name, propSchema) <- KM.toList props
                  , Just val <- [KM.lookup name obj]
                  ]
              _ -> []
          ]
      _ -> []

    allOfErrors :: Value -> KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    allOfErrors rt o inst path =
      case KM.lookup "allOf" o of
        Just (Array subs) ->
          concat (zipWith
            (\i s -> go rt s inst (path <> [T.pack (show (i :: Int))]))
            [0 ..] (V.toList subs))
        _ -> []

    conditionalErr :: Value -> KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    conditionalErr rt o inst path =
      case KM.lookup "if" o of
        Nothing -> []
        Just ifSchema ->
          let ifOk   = null (go rt ifSchema inst path)
              branch = if ifOk then KM.lookup "then" o
                               else KM.lookup "else" o
          in case branch of
               Just b -> go rt b inst path
               Nothing -> []

    formatErrors :: KM.KeyMap Value -> Value -> [Text] -> [ValidationError]
    formatErrors o inst path =
      case KM.lookup "format" o of
        Just (String "date-time") -> case inst of
          String t
            | isIso8601 t -> []
            | otherwise -> [ValidationError (renderPath path)
                ("not an ISO8601 date-time: " <> T.pack (show t))]
          _ -> []
        _ -> []

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Resolve a local JSON Pointer such as @#\/definitions\/zone@.
resolveRef :: Value -> Text -> Maybe Value
resolveRef root target = walk (T.splitOn "/" (T.drop 1 target))
  where
    walk [] = Just root
    walk (seg : more)
      | T.null seg = walk more
      | otherwise  = case root of
          Object o -> KM.lookup (Key.fromText (unescape seg)) o >>= flip descend more
          _        -> Nothing
    descend v [] = Just v
    descend v (seg : more) = case v of
      Object o -> KM.lookup (Key.fromText (unescape seg)) o >>= flip descend more
      _        -> Nothing
    unescape = T.replace "~1" "/" . T.replace "~0" "~"

renderPath :: [Text] -> Text
renderPath []   = "/"
renderPath segs = "/" <> T.intercalate "/" segs

-- | Check the @YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)@ shape the standard asks
-- for in its @timestamp@ field.
isIso8601 :: Text -> Bool
isIso8601 t = case T.splitOn "T" t of
  [d, rest] -> isDate d && isClock rest
  _         -> False
  where
    isDate s =
      T.length s == 10
        && T.index s 4 == '-'
        && T.index s 7 == '-'
        && all C.isDigit [T.index s i | i <- [0 .. 3] ++ [5, 6] ++ [8, 9]]
    isClock s =
      T.length s >= 9
        && T.index s 2 == ':'
        && T.index s 5 == ':'
        && all C.isDigit [T.index s i | i <- [0, 1, 3, 4, 6, 7]]
        && zone (T.drop 8 s)
    zone z = case T.uncons z of
      Just ('Z', "")    -> True
      Just ('.', frac)  -> case T.break (== 'Z') frac of
        (f, "Z") -> not (T.null f) && all C.isDigit (T.unpack f)
        _        -> offset frac
      _ -> offset z
    offset z = case T.uncons z of
      Just (s, rest)
        | s `elem` ("+-" :: String) ->
            T.length rest == 5
              && T.index rest 2 == ':'
              && all C.isDigit [T.index rest i | i <- [0, 1, 3, 4]]
      _ -> False
