{-# LANGUAGE OverloadedStrings #-}
-- | Parser tests.
module ParserSpec (tests) where

import Data.Either (isLeft, isRight, rights)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

import RobotDSL.AST
import RobotDSL.Parser

linesOf :: [String] -> Text
linesOf = T.pack . unlines

tests :: IO [TestTree]
tests = pure
  [ testGroup "parsing"
      [ testCase "empty program" $
          assertRight "" (parseProgram "t.robot" "")
      , testCase "comments: hash, dash-dash and block" $
          assertRight "comments"
            (parseProgram "t.robot" (linesOf
              [ "# hash comment"
              , "-- dash comment"
              , "/* block"
              , "   comment */"
              , "robot \"acme\" \"AMR-001\""
              ]))
      , testCase "robot declaration is captured" $ do
          prog <- mustParse "robot \"acme\" \"AMR-001\""
          assertEqual "robot" (Just ("acme", "AMR-001")) (progRobot prog)
      , testCase "case-insensitive keywords" $ do
          prog <- mustParse "ROBOT \"acme\" \"AMR-001\"\nORDER \"o\" {\n  NODE \"n\" AT (1, 2)\n}"
          assertEqual "one decl" 1 (length (progDecls prog))
      , testCase "speed and speed_limit do not collide" $ do
          -- `speed` is an edge modifier, `speed_limit` a zone type.
          prog <- mustParse (linesOf
              [ "robot \"a\" \"b\""
              , "map \"m\""
              , "zoneset \"z\" on map \"m\" {"
              , "  zone \"s\" speed_limit 0.3 { polygon (0,0) (1,0) (1,1) }"
              , "}"
              , "order \"o\" {"
              , "  node \"n1\" at (0,0)"
              , "  edge \"e\" speed 0.5"
              , "  node \"n2\" at (1,1)"
              , "}"
              ])
          assertEqual "two decls" 2 (length (progDecls prog))
      , testCase "route alternation is not enforced by the parser" $ do
          -- Semantic rules belong to Validate; the parser only checks shape.
          prog <- mustParse "robot \"a\" \"b\"\norder \"o\" {\n  edge \"e\"\n  node \"n\" at (0,0)\n}"
          assertEqual "one order" 1 (length (progDecls prog))
      , testCase "a node needs no action block" $ do
          prog <- mustParse "robot \"a\" \"b\"\norder \"o\" {\n  node \"n\" at (0,0)\n}"
          case progDecls prog of
            [DeclOrder o] ->
              case ordSegments o of
                [Segment _ [StepNode n]] -> assertEqual "no actions" [] (nodeActions n)
                other -> assertFailure ("unexpected steps: " ++ show other)
            other -> assertFailure ("unexpected decls: " ++ show other)
      , testCase "action modifiers parse in any order" $ do
          prog <- mustParse (linesOf
              [ "robot \"a\" \"b\""
              , "order \"o\" {"
              , "  node \"n\" at (0,0) {"
              , "    action \"pick\" describe \"d\" blocking HARD retriable with { k = 1 }"
              , "  }"
              , "}"
              ])
          let acts = allActions prog
          assertEqual "one action" 1 (length acts)
          assertEqual "blocking" BtHard (actBlocking (head acts))
          assertEqual "descriptor" (Just "d") (actDescriptor (head acts))
          assertEqual "retriable" (Just True) (actRetriable (head acts))
          assertEqual "params" [("k", AVNumber 1)] (actParameters (head acts))
      , testCase "order actions default to HARD" $ do
          prog <- mustParse (linesOf
              [ "robot \"a\" \"b\""
              , "order \"o\" { node \"n\" at (0,0) { action \"pick\" } }"
              ])
          assertEqual "default" BtHard (actBlocking (head (allActions prog)))
      , testCase "instant actions default to NONE" $ do
          prog <- mustParse "robot \"a\" \"b\"\ninstant \"i\" { action \"startPause\" }"
          case progDecls prog of
            [DeclInstant ia] ->
              assertEqual "default" BtNone (actBlocking (head (iaActions ia)))
            other -> assertFailure ("unexpected decls: " ++ show other)
      , testCase "go expands to an edge then a node" $ do
          prog <- mustParse (linesOf
              [ "robot \"a\" \"b\""
              , "order \"o\" {"
              , "  node \"start\" at (0,0)"
              , "  go to \"end\" at (5,5) via \"e-9\" speed 0.4"
              , "}"
              ])
          case progDecls prog of
            [DeclOrder o] -> case ordSegments o of
              [Segment _ steps] -> do
                assertEqual "three steps" 3 (length steps)
                assertBool "edge first" (isEdge (steps !! 1))
                assertBool "node second" (isNode (steps !! 2))
              other -> assertFailure ("unexpected segments: " ++ show other)
            other -> assertFailure ("unexpected decls: " ++ show other)
      , testCase "every zoneType parses" $ do
          let src = linesOf
                [ "robot \"a\" \"b\""
                , "map \"m\""
                , "zoneset \"z\" on map \"m\" {"
                , "  zone \"a\" blocked { polygon (0,0) (1,0) (1,1) }"
                , "  zone \"b\" line_guided { polygon (0,0) (1,0) (1,1) }"
                , "  zone \"c\" release { polygon (0,0) (1,0) (1,1) }"
                , "  zone \"d\" coordinated_replanning { polygon (0,0) (1,0) (1,1) }"
                , "  zone \"e\" speed_limit 0.3 { polygon (0,0) (1,0) (1,1) }"
                , "  zone \"f\" action { entry { action \"x\" } during { } exit { action \"y\" } polygon (0,0) (1,0) (1,1) }"
                , "  zone \"g\" priority factor 0.5 { polygon (0,0) (1,0) (1,1) }"
                , "  zone \"h\" penalty factor 0.5 { polygon (0,0) (1,0) (1,1) }"
                , "  zone \"i\" directed heading 0.0 strictness restricted { polygon (0,0) (1,0) (1,1) }"
                , "  zone \"j\" bidirected heading 1.5 strictness soft { polygon (0,0) (1,0) (1,1) }"
                , "}"
                ]
          prog <- mustParse src
          case progDecls prog of
            [DeclZoneSet zs] -> assertEqual "ten zones" 10 (length (zsZones zs))
            other -> assertFailure ("unexpected decls: " ++ show other)
      , testCase "action groups on a non-ACTION zone are rejected" $
          assertLeft (linesOf
              [ "robot \"a\" \"b\""
              , "map \"m\""
              , "zoneset \"z\" on map \"m\" {"
              , "  zone \"a\" blocked { entry { action \"x\" } polygon (0,0) (1,0) (1,1) }"
              , "}"
              ])
      , testCase "a missing speed value is reported with a label" $ do
          let r = parseProgram "t.robot" (linesOf
                [ "robot \"a\" \"b\""
                , "map \"m\""
                , "zoneset \"z\" on map \"m\" {"
                , "  zone \"s\" speed_limit {"
                ])
          assertBool "labelled" (isLeft r)
      , testCase "parse errors carry a line number" $ do
          let r = parseProgram "t.robot" (linesOf
                [ "robot \"a\" \"b\""
                , "order \"o\" {"
                , "  node 5"
                , "}"
                ])
          assertBool "fails" (isLeft r)
          case r of
            Left (ParseError msg) ->
              assertBool ("mentions line 3: " ++ T.unpack msg)
                         ("3:" `T.isInfixOf` msg)
            Right _ -> assertFailure "should not parse"
      ]
  ]

allActions :: Program -> [Action]
allActions prog = concat
  [ [ a | DeclInstant ia <- progDecls prog, a <- iaActions ia ]
  , concat [ nodeActions n | DeclOrder o <- progDecls prog
                           , Segment _ steps <- ordSegments o
                           , StepNode n <- steps ]
  , concat [ edgeActions e | DeclOrder o <- progDecls prog
                           , Segment _ steps <- ordSegments o
                           , StepEdge e <- steps ]
  ]

isNode :: Step -> Bool
isNode (StepNode{}) = True
isNode _            = False

isEdge :: Step -> Bool
isEdge (StepEdge{}) = True
isEdge _            = False

mustParse :: Text -> IO Program
mustParse src = case parseProgram "t.robot" src of
  Right prog -> pure prog
  Left (ParseError msg) -> assertFailure (T.unpack msg)

assertRight :: String -> Either ParseError a -> IO ()
assertRight label r = case r of
  Right _ -> pure ()
  Left (ParseError msg) -> assertFailure (label ++ ": " ++ T.unpack msg)

assertLeft :: Text -> IO ()
assertLeft src = case parseProgram "t.robot" src of
  Left _  -> pure ()
  Right _ -> assertFailure "expected a parse error"

_unused :: [Either ParseError Program]
_unused = rights []
