-- | A general logging effect suitable for recording events as they happen in
-- | the application, including debugging logs. Should not be used to report
-- | important events to registry users; for that, use the Comment effect.
module Registry.App.Effect.Log where

import Registry.App.Prelude

import Ansi.Codes (GraphicsParam)
import Data.Array as Array
import Data.Formatter.DateTime as Formatter.DateTime
import Dodo (Doc)
import Dodo as Dodo
import Dodo.Ansi as Ansi
import Effect.Aff as Aff
import Effect.Class.Console as Console
import Node.FS.Aff as FS.Aff
import Registry.API.V1 (JobId, LogLevel(..), printLogLevel)
import Registry.App.SQLite (SQLite)
import Registry.App.SQLite as SQLite
import Registry.Internal.Format as Internal.Format
import Registry.PackageName as PackageName
import Registry.Range as Range
import Registry.Version as Version
import Run (AFF, EFFECT, Run)
import Run as Run
import Type.Proxy (Proxy(..))

class Loggable a where
  toLog :: a -> Doc GraphicsParam

instance Loggable (Doc GraphicsParam) where
  toLog = identity

instance Loggable String where
  toLog = Dodo.text

instance Loggable PackageName where
  toLog = toLog <<< PackageName.print

instance Loggable Version where
  toLog = toLog <<< Version.print

instance Loggable Range where
  toLog = toLog <<< Range.print

data Log a = Log LogLevel (Doc GraphicsParam) a

derive instance Functor Log

-- | An effect for recording logs about events in the application
type LOG r = (log :: Log | r)

_log :: Proxy "log"
_log = Proxy

log :: forall a r. Loggable a => LogLevel -> a -> Run (LOG + r) Unit
log level message = Run.lift _log (Log level (toLog message) unit)

debug :: forall a r. Loggable a => a -> Run (LOG + r) Unit
debug = log Debug <<< toLog

info :: forall a r. Loggable a => a -> Run (LOG + r) Unit
info = log Info <<< toLog

warn :: forall a r. Loggable a => a -> Run (LOG + r) Unit
warn = log Warn <<< toLog

error :: forall a r. Loggable a => a -> Run (LOG + r) Unit
error = log Error <<< toLog

interpret :: forall a r. (Log ~> Run r) -> Run (LOG + r) a -> Run r a
interpret handler = Run.interpret (Run.on _log handler Run.send)

-- | Write logs to the terminal only.
handleTerminal :: forall a r. LogVerbosity -> Log a -> Run (EFFECT + r) a
handleTerminal verbosity = case _ of
  Log level message next -> do
    let
      printed = Dodo.print Ansi.ansiGraphics Dodo.twoSpaces $ case level of
        Debug -> Ansi.foreground Ansi.Blue message
        Info -> message
        Warn -> Ansi.foreground Ansi.Yellow (Dodo.text "[WARNING] ") <> message
        Error -> Ansi.foreground Ansi.Red (Dodo.text "[ERROR] ") <> message

    Run.liftEffect case verbosity of
      Quiet -> pure unit
      Normal -> when (level /= Debug) (Console.log printed)
      Verbose -> Console.log printed

    pure next

-- | Write logs to the specified logfile.
handleFs :: forall a r. LogVerbosity -> FilePath -> Log a -> Run (AFF + EFFECT + r) a
handleFs verbosity logfile action = case action of
  Log level message next -> do
    let
      attemptWrite = do
        now <- nowUTC

        let
          time = Formatter.DateTime.format Internal.Format.iso8601DateTime now
          formatted = Dodo.print Dodo.plainText Dodo.twoSpaces $ Array.fold
            [ Dodo.text "["
            , Dodo.text time
            , Dodo.space
            , Dodo.text (printLogLevel level)
            , Dodo.text "]"
            , Dodo.space
            , message
            , Dodo.break
            ]

        Run.liftAff (Aff.attempt (FS.Aff.appendTextFile UTF8 logfile formatted)) >>= case _ of
          Left err -> Console.error $ "LOG ERROR: Failed to write to file " <> logfile <> ": " <> Aff.message err
          Right _ -> pure unit

    case verbosity of
      Quiet -> pure unit
      Normal -> when (level /= Debug) attemptWrite
      Verbose -> attemptWrite

    pure next

type LogDbEnv =
  { db :: SQLite
  , job :: JobId
  }

-- | Handle a log by recording it in the database.
handleDb :: forall a r. LogDbEnv -> Log a -> Run (EFFECT + r) a
handleDb env = case _ of
  Log level message next -> do
    timestamp <- nowUTC
    let
      msg = Dodo.print Dodo.plainText Dodo.twoSpaces (toLog message)
      row = { timestamp, level, jobId: env.job, message: msg }
    Run.liftEffect $ SQLite.insertLog env.db row
    pure next
