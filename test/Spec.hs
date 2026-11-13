{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Test.Tasty

import qualified ParserSpec
import qualified EmitSpec
import qualified SchemaSpec

main :: IO ()
main = do
  groups <- sequence [ParserSpec.tests, EmitSpec.tests, SchemaSpec.tests]
  defaultMain (testGroup "robotdsl" (concat groups))
