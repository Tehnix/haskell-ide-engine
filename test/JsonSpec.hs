{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | Test for JSON serialization
module JsonSpec where

import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.SemanticTypes

import           Data.Aeson
import           Data.Text
import           Test.QuickCheck hiding (Success)
import           Test.QuickCheck.Instances ()
import           Test.Hspec
import           Test.Hspec.QuickCheck

-- import Debug.Trace
-- ---------------------------------------------------------------------

main :: IO ()
main = hspec spec

spec :: Spec
spec = describe "dispatcher" jsonSpec

-- -- |Used when running from ghci, and it sets the current directory to ./tests
-- tt :: IO ()
-- tt = do
--   cd ".."
--   hspec spec

-- ---------------------------------------------------------------------

jsonSpec :: Spec
jsonSpec = do
  describe "Valid Response JSON Object round trip" $ do
    prop "Text" (propertyValidRoundtrip :: Text -> Bool)
    prop "[Text]" (propertyValidRoundtrip :: [Text] -> Bool)
    prop "()" (propertyValidRoundtrip :: () -> Bool)
    prop "Aeson.Object" (propertyValidRoundtrip :: Object -> Bool)
    prop "CommandDescriptor" (propertyValidRoundtrip :: UntaggedCommandDescriptor -> Bool)
    prop "ExtendedCommandDescriptor" (propertyValidRoundtrip :: ExtendedCommandDescriptor -> Bool)
    prop "IdePlugins" (propertyValidRoundtrip :: IdePlugins -> Bool)
    prop "TypeInfo" (propertyValidRoundtrip :: TypeInfo -> Bool)
    prop "ModuleList" (propertyValidRoundtrip :: ModuleList -> Bool)

  describe "General JSON instances round trip" $ do
    prop "Pos" (propertyJsonRoundtrip :: Position -> Bool)
    prop "ParamVal 'PtPos" (propertyJsonRoundtrip :: ParamVal 'PtPos -> Bool)
    prop "ParamValP" (propertyJsonRoundtrip :: ParamValP -> Bool)
    prop "CabalSection" (propertyJsonRoundtrip :: CabalSection -> Bool)
    prop "AcceptedContext" (propertyJsonRoundtrip :: AcceptedContext -> Bool)
    prop "ParamType" (propertyJsonRoundtrip :: ParamType -> Bool)
    prop "ParamDescription" (propertyJsonRoundtrip :: ParamDescription -> Bool)
    prop "CommandDescriptor" (propertyJsonRoundtrip :: UntaggedCommandDescriptor -> Bool)
    prop "Service" (propertyJsonRoundtrip :: Service -> Bool)
    prop "IdeRequest" (propertyJsonRoundtrip :: IdeRequest -> Bool)
    prop "IdeErrorCode" (propertyJsonRoundtrip :: IdeErrorCode -> Bool)
    prop "IdeError" (propertyJsonRoundtrip :: IdeError -> Bool)

-- ---------------------------------------------------------------------

propertyJsonRoundtrip :: (Eq a, ToJSON a, FromJSON a) => a -> Bool
propertyJsonRoundtrip a = Success a == fromJSON (toJSON a)

propertyValidRoundtrip :: (Eq a, ValidResponse a) => a -> Bool
propertyValidRoundtrip a = Success a == fromJSON (toJSON a)

-- enough for our needs
instance Arbitrary Value where
  arbitrary = do
    s <- arbitrary
    return $ String s

instance Arbitrary UntaggedCommandDescriptor where
  arbitrary = CommandDesc
    <$> arbitrary
    <*> arbitrary
    <*> smallList arbitrary
    <*> smallList arbitraryBoundedEnum
    <*> smallList arbitrary
    <*> arbitrary
    <*> arbitrary

instance Arbitrary ExtendedCommandDescriptor where
  arbitrary = ExtendedCommandDescriptor
    <$> arbitrary
    <*> arbitrary

instance Arbitrary ParamDescription where
  arbitrary = do
    i <- choose (1::Int,2)
    case i of
      1 -> RP <$> arbitrary <*> arbitrary <*> arbitraryBoundedEnum
      _ -> OP <$> arbitrary <*> arbitrary <*> arbitraryBoundedEnum


instance Arbitrary Service where
  arbitrary = Service <$> arbitrary

instance Arbitrary UntaggedPluginDescriptor where
  arbitrary = PluginDescriptor <$>
              arbitrary <*>
              arbitrary <*>
              smallList arbitrary <*>
              smallList arbitrary <*>
              smallList arbitrary

-- | make lists of maximum length 3 for test performance
smallList :: Gen a -> Gen [a]
smallList = resize 3 . listOf

instance Arbitrary UntaggedCommand where
  arbitrary = Command <$> arbitrary <*> pure (CmdAsync (\_ _ _ -> return ())::CommandFunc Text)

-- | Sufficient for tests
instance Eq UntaggedPluginDescriptor where
  a == b = show a == show b

instance Arbitrary Uri where
  arbitrary = filePathToUri <$> arbitrary

instance Arbitrary ParamValP where
  arbitrary = do
    i <- choose (1::Int,9)
    case i of
      1 -> ParamTextP       <$> arbitrary
      2 -> ParamIntP        <$> arbitrary
      3 -> ParamBoolP       <$> arbitrary
      4 -> ParamFileP       <$> arbitrary
      5 -> ParamPosP        <$> arbitrary
      6 -> ParamRangeP      <$> arbitrary
      7 -> ParamLocP        <$> arbitrary
      8 -> ParamTextDocIdP  <$> arbitrary
      _ -> ParamTextDocPosP <$> arbitrary

instance Arbitrary Range where
  arbitrary = Range <$> arbitrary <*> arbitrary

instance Arbitrary Location where
  arbitrary = Location <$> arbitrary <*> arbitrary

instance Arbitrary TextDocumentIdentifier where
  arbitrary = TextDocumentIdentifier <$> arbitrary

instance Arbitrary TextDocumentPositionParams where
  arbitrary = TextDocumentPositionParams <$> arbitrary <*> arbitrary

instance Arbitrary CabalSection where
  arbitrary = CabalSection <$> arbitrary

instance Arbitrary AcceptedContext where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary ParamType where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary IdeErrorCode where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary IdeError where
  arbitrary = IdeError <$> arbitrary <*> arbitrary <*> arbitrary

-- | Sufficient for tests
instance Eq IdeRequest where
  a == b = show a == show b

instance Arbitrary IdeRequest where
  arbitrary = IdeRequest <$> arbitrary <*> arbitrary

instance Arbitrary TypeInfo where
  arbitrary = TypeInfo <$> smallList arbitrary

instance Arbitrary TypeResult where
  arbitrary = TypeResult <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary IdePlugins where
  arbitrary = IdePlugins <$> arbitrary

instance Arbitrary ModuleList where
  arbitrary = ModuleList <$> smallList arbitrary

instance Arbitrary Position where
  arbitrary = do
    Positive l <- arbitrary
    Positive c <- arbitrary
    return $ Position l c

instance Arbitrary (ParamVal 'PtPos) where
  arbitrary = ParamPos <$> arbitrary

instance Arbitrary Save where
  arbitrary = oneof [return SaveNone, return SaveAll]
