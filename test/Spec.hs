{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Test.Tasty

import qualified ParserSpec
import qualified EmitSpec
import qualified SchemaSpec
import qualified AgentSpec

main :: IO ()
main = do
  groups <- sequence [ParserSpec.tests, EmitSpec.tests, SchemaSpec.tests
                     , AgentSpec.tests]
  defaultMain (testGroup "robotdsl" (concat groups))
