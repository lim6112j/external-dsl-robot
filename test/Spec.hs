{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Test.Tasty

import qualified ParserSpec
import qualified EmitSpec
import qualified SchemaSpec
import qualified AgentSpec
import qualified FleetSpec
import qualified PreviewSpec

main :: IO ()
main = do
  groups <- sequence [ParserSpec.tests, EmitSpec.tests, SchemaSpec.tests
                     , AgentSpec.tests, FleetSpec.tests, PreviewSpec.tests]
  defaultMain (testGroup "robotdsl" (concat groups))
