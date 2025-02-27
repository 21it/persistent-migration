{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Migration (testMigrations) where

import Control.Monad.Reader (runReaderT)
import qualified Data.Text as Text
import Database.Persist.Migration
import Database.Persist.Migration.Core (getMigration)
import Test.Tasty (TestName, TestTree, testGroup)
import Utils.Backends
  ( MockDatabase (..),
    defaultDatabase,
    setDatabase,
    withTestBackend,
  )
import Utils.Goldens (goldenVsText)

-- | Build a test suite for the given MigrateBackend.
testMigrations :: FilePath -> MigrateBackend -> TestTree
testMigrations dir backend =
  testGroup
    "goldens"
    [ goldenMigration'
        "Basic migration"
        defaultDatabase
        [ 0 ~> 1
            := [ CreateTable
                   { name = "person",
                     schema =
                       [ Column "id" SqlInt32 [],
                         Column "name" SqlString [NotNull],
                         Column "age" SqlInt32 [NotNull],
                         Column "alive" SqlBool [NotNull],
                         Column "hometown" SqlInt64 [References ("cities", "id")]
                       ],
                     constraints =
                       [ PrimaryKey ["id"],
                         Unique "unique_name" ["name"]
                       ]
                   }
               ],
          1 ~> 2
            := [ AddColumn "person" (Column "gender" SqlString []) Nothing,
                 DropColumn ("person", "alive")
               ],
          2 ~> 3
            := [ DropTable "person"
               ]
        ],
      goldenMigration'
        "Partial migration"
        (withVersion 1)
        [ 0 ~> 1 := [createTablePerson []],
          1 ~> 2 := [DropTable "person"]
        ],
      goldenMigration'
        "Complete migration"
        (withVersion 2)
        [ 0 ~> 1 := [createTablePerson []],
          1 ~> 2 := [DropTable "person"]
        ],
      goldenMigration'
        "Migration with shorter path"
        defaultDatabase
        [ 0 ~> 1 := [createTablePerson []],
          1 ~> 2 := [AddColumn "person" (Column "gender" SqlString []) Nothing],
          0 ~> 2 := [createTablePerson [Column "gender" SqlString []]]
        ],
      goldenMigration'
        "Partial migration avoids shorter path"
        (withVersion 1)
        [ 0 ~> 1 := [createTablePerson []],
          1 ~> 2 := [AddColumn "person" (Column "gender" SqlString []) Nothing],
          0 ~> 2 := [createTablePerson [Column "gender" SqlString []]]
        ]
    ]
  where
    goldenMigration' = goldenMigration dir backend

{- Helpers -}

-- | Run a goldens test for a migration.
goldenMigration ::
  FilePath -> MigrateBackend -> TestName -> MockDatabase -> Migration -> TestTree
goldenMigration dir backend testName testBackend migration = goldenVsText dir testName $ do
  setDatabase testBackend
  MigrateSql {..} <- concatSql Text.unlines <$> getMigration' migration
  return $ Text.unlines [sqlText, Text.pack $ show sqlVals]
  where
    getMigration' = withTestBackend . runReaderT . getMigration backend defaultSettings

-- | Set the version in the MockDatabase.
withVersion :: Version -> MockDatabase
withVersion v = defaultDatabase {version = Just v}

-- | Create a basic 'person' table.
createTablePerson :: [Column] -> Operation
createTablePerson cols =
  CreateTable
    { name = "person",
      schema = Column "id" SqlInt64 [NotNull, AutoIncrement] : cols,
      constraints = [PrimaryKey ["id"]]
    }
