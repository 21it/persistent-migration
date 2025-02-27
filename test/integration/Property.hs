{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module Property
  ( testProperties,
  )
where

import Control.Monad (unless)
import Control.Monad.Catch (SomeException (..), try)
import Control.Monad.IO.Class (liftIO)
import Data.List (nub)
import Data.Maybe (mapMaybe)
import Data.Pool (Pool)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Database.Persist.Migration
import Database.Persist.Sql (SqlBackend, SqlPersistT)
import Test.QuickCheck
import Test.QuickCheck.Monadic (PropertyM, monadicIO, pick, run, stop)
import Test.QuickCheck.Property (rejected)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)
import Utils.QuickCheck
  ( ColumnIdentifier (..),
    CreateTable' (..),
    Identifier (..),
    genPersistValue,
    toOperation,
  )
import Utils.RunSql (runSql)

-- | A test suite for testing migration properties.
testProperties :: MigrateBackend -> IO (Pool SqlBackend) -> TestTree
testProperties backend getPool =
  testGroup
    "properties"
    [ testProperty "Create and drop tables" $
        withCreateTable $ const $ return (),
      testProperty "Rename table" $
        withCreateTable $ \(table, fkTables) -> do
          let tableName = ctName table
              fkNames = map ctName fkTables
          Identifier newName <-
            pick $
              arbitrary `suchThat` ((`notElem` tableName : fkNames) . unIdent)
          runSqlPool' $ do
            runOperation' $ RenameTable tableName newName
            runOperation' $ DropTable newName,
      testProperty "Add UNIQUE constraint" $
        withCreateTable $ \(table, _) -> do
          let getUniqueCols =
                \case
                  PrimaryKey _ -> []
                  Unique _ cols -> cols
              tableCols = map colName $ ctSchema table
              uniqueCols = concatMap getUniqueCols $ ctConstraints table
              nonUniqueCols = take 32 $ filter (`notElem` uniqueCols) tableCols
          if null nonUniqueCols
            then return False
            else do
              let uniqueName =
                    Text.take 63 $ "unique_" <> Text.intercalate "_" nonUniqueCols
              runSqlPool' $
                runOperation' $
                  AddConstraint (ctName table) $ Unique uniqueName nonUniqueCols
              return True,
      testProperty "Drop UNIQUE constraint" $
        withCreateTable $ \(table, _) -> do
          let getUniqueName =
                \case
                  PrimaryKey _ -> Nothing
                  Unique n _ -> Just n
              uniqueNames = mapMaybe getUniqueName $ ctConstraints table
          if null uniqueNames
            then return False
            else do
              uniqueName <- pick $ elements uniqueNames
              runSqlPool' $
                runOperation' $ DropConstraint (ctName table) uniqueName
              return True,
      testProperty "Add column" $
        withCreateTable $ \(table, fkTables) ->
          -- generate a new column
          do
            col <- pick arbitrary
            -- pick a new name for the column
            let cols = map colName $ ctSchema table
            Identifier newName <-
              pick $ arbitrary `suchThat` ((`notElem` cols) . unIdent)
            -- if foreign key tables exist, update any foreign key references to point to one of those.
            -- otherwise, strip out any foreign key references.
            let splitProps [] = (False, [])
                splitProps (x : xs) =
                  let (mRef, props) = splitProps xs
                   in case x of
                        References _ -> (True, props)
                        AutoIncrement -> (mRef, props) -- don't test adding AutoIncrement columns
                        _ -> (mRef, x : props)
            col' <-
              let (hasReference, props) = splitProps $ colProps col
               in if null fkTables || not hasReference
                    then return col {colProps = props}
                    else do
                      fkTable <- pick $ ctName <$> elements fkTables
                      return $ col {colProps = References (fkTable, "id") : props}
            -- pick a default value according to nullability and sqltype
            defaultVal <- pick $ genPersistValue $ colType col
            defaultVal' <-
              if NotNull `elem` colProps col
                then return $ Just defaultVal
                else pick $ elements [Nothing, Just defaultVal]
            runSqlPool' $
              runOperation' $
                AddColumn (ctName table) col' {colName = newName} defaultVal',
      testProperty "Rename column" $
        withCreateTable $ \(table, _) -> do
          let cols = map colName $ ctSchema table
          col <- pick $ elements cols
          ColumnIdentifier newName <-
            pick $ arbitrary `suchThat` ((`notElem` cols) . unColIdent)
          runSqlPool' $ runOperation' $ RenameColumn (ctName table) col newName,
      testProperty "Drop column" $
        withCreateTable $ \(table, _) -> do
          let cols = map colName $ ctSchema table
          col <- pick $ elements cols
          runSqlPool' $ runOperation' $ DropColumn (ctName table, col)
    ]
  where
    runSqlPool' = runSqlPool getPool
    runOperation' = runOperation backend

    withCreateTable ::
      PseudoBool a =>
      ((CreateTable', [CreateTable']) -> PropertyM IO a) ->
      Property
    withCreateTable action =
      monadicIO $ do
        table <- pick arbitrary
        fkTables <- pick $ getForeignKeyTables table
        runSqlPool' $ mapM_ (runOperation' . toOperation) (fkTables ++ [table])
        isSuccess <- toBool <$> action (table, fkTables)
        runSqlPool' $ mapM_ dropTable' (table : fkTables)
        unless isSuccess $ stop rejected
    dropTable' CreateTable' {ctName} = runOperation' $ DropTable ctName

{- Helpers -}

-- | Run the given Sql query in the given SqlBackend.
runSqlPool :: IO (Pool SqlBackend) -> SqlPersistT IO () -> PropertyM IO ()
runSqlPool getPool f = run $ getPool >>= \pool -> runSql pool f

-- | Run the given operation.
runOperation :: MigrateBackend -> Operation -> SqlPersistT IO ()
runOperation backend operation = do
  case validateOperation operation of
    Right () -> return ()
    Left msg -> do
      liftIO $ putStrLn "\n*** Failure: validateOperation failed"
      fail msg
  getMigrationSql backend operation >>= mapM_ rawExecutePrint
  where
    -- if rawExecute fails, show the sql query run

    rawExecutePrint sql =
      try (executeSql sql) >>= \case
        Right () -> return ()
        Left (SomeException e) -> do
          liftIO $ do
            putStrLn "\n*** Failure:"
            Text.putStrLn $ sqlText sql
            print $ sqlVals sql
          fail $ show e

-- | Get the CreateTable operations that are necessary for the foreign keys in the
-- given CreateTable operation.
getForeignKeyTables :: CreateTable' -> Gen [CreateTable']
getForeignKeyTables ct =
  zipWith modifyTable neededTables <$> vectorOf (length neededTables) arbitrary
  where
    neededTables =
      nub $ concatMap (mapMaybe getReferenceTable . colProps) $ ctSchema ct
    getReferenceTable =
      \case
        References (table, _) -> Just table
        _ -> Nothing
    isReference =
      \case
        References _ -> True
        _ -> False
    noFKs = filter (not . isReference) . colProps
    modifyTable name ct' =
      ct'
        { ctName = name,
          ctSchema = map (\col -> col {colProps = noFKs col}) $ ctSchema ct'
        }

class PseudoBool a where
  toBool :: a -> Bool

instance PseudoBool () where
  toBool = const True

instance PseudoBool Bool where
  toBool = id
