-- | 'Trace' for named logging.

{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Pos.Util.Trace.Named
    ( TraceNamed
    , LogNamed (..)
    , TrU.LogItem
    , setupLogging
    , appendName
    -- * log functions
    , logMessage, logMessageS, logMessageP
    , logDebug,   logDebugS,   logDebugP
    , logError,   logErrorS,   logErrorP
    , logInfo,    logInfoS,    logInfoP
    , logNotice,  logNoticeS,  logNoticeP
    , logWarning, logWarningS, logWarningP
    ) where

import           Universum

import           Data.Functor.Contravariant (Op (..), contramap)
import qualified Data.Text as T
import qualified Pos.Util.Log as Log
import           Pos.Util.Trace (Trace (..), traceWith)
import qualified Pos.Util.Trace.Unstructured as TrU (LogItem (..), LogPrivacy (..))

import           Pos.Util.Log.LogSafe (logMCond, selectPublicLogs, selectSecretLogs)

type TraceNamed m = Trace m (LogNamed TrU.LogItem)

-- | Attach a 'LoggerName' to something.
data LogNamed item = LogNamed
    { lnName :: Log.LoggerName
    , lnItem :: item
    } deriving (Show)

traceNamedItem
    :: TraceNamed m
    -> TrU.LogPrivacy
    -> Log.Severity
    -> Text
    -> m ()
traceNamedItem logTrace liPrivacy liSeverity liMessage =
    traceWith (named logTrace) TrU.LogItem{..}

logMessage, logMessageS, logMessageP :: TraceNamed m -> Log.Severity -> Text -> m ()
logMessage logTrace  = traceNamedItem logTrace TrU.Both
logMessageS logTrace = traceNamedItem logTrace TrU.Private
logMessageP logTrace = traceNamedItem logTrace TrU.Public

logDebug, logInfo, logNotice, logWarning, logError
    :: TraceNamed m -> Text -> m ()
logDebug logTrace   = traceNamedItem logTrace TrU.Both Log.Debug
logInfo logTrace    = traceNamedItem logTrace TrU.Both Log.Info
logNotice logTrace  = traceNamedItem logTrace TrU.Both Log.Notice
logWarning logTrace = traceNamedItem logTrace TrU.Both Log.Warning
logError logTrace   = traceNamedItem logTrace TrU.Both Log.Error
logDebugS, logInfoS, logNoticeS, logWarningS, logErrorS
    :: Trace m (LogNamed TrU.LogItem) -> Text -> m ()
logDebugS logTrace   = traceNamedItem logTrace TrU.Private Log.Debug
logInfoS logTrace    = traceNamedItem logTrace TrU.Private Log.Info
logNoticeS logTrace  = traceNamedItem logTrace TrU.Private Log.Notice
logWarningS logTrace = traceNamedItem logTrace TrU.Private Log.Warning
logErrorS logTrace   = traceNamedItem logTrace TrU.Private Log.Error
logDebugP, logInfoP, logNoticeP, logWarningP, logErrorP
    :: Trace m (LogNamed TrU.LogItem) -> Text -> m ()
logDebugP logTrace   = traceNamedItem logTrace TrU.Public Log.Debug
logInfoP logTrace    = traceNamedItem logTrace TrU.Public Log.Info
logNoticeP logTrace  = traceNamedItem logTrace TrU.Public Log.Notice
logWarningP logTrace = traceNamedItem logTrace TrU.Public Log.Warning
logErrorP logTrace   = traceNamedItem logTrace TrU.Public Log.Error

modifyName
    :: (Log.LoggerName -> Log.LoggerName)
    -> TraceNamed m
    -> TraceNamed m
modifyName k = contramap f
  where
    f (LogNamed name item) = LogNamed (k name) item

appendName :: Log.LoggerName -> TraceNamed m -> TraceNamed m
appendName lname = modifyName (\e -> ('.' `T.cons` lname) <> e)

{-
setName :: Log.LoggerName -> TraceNamed m -> TraceNamed m
setName name = modifyName (const name)
-}

named :: Trace m (LogNamed i) -> Trace m i
named = contramap (LogNamed mempty)

-- | setup logging and return a Trace
setupLogging :: Log.LoggerConfig -> Log.LoggerName -> IO (TraceNamed IO)
setupLogging lc ln = do
    lh <- Log.setupLogging lc
    let nt = namedTrace lh
    return $ appendName ln nt

namedTrace :: Log.LoggingHandler -> TraceNamed IO --Trace IO (LogNamed TrU.LogItem)
namedTrace lh = Trace $ Op $ \namedLogitem ->
    let privacy = TrU.liPrivacy (lnItem namedLogitem)
        loggerName = T.tail $ lnName namedLogitem
        severity = TrU.liSeverity (lnItem namedLogitem)
        message = TrU.liMessage (lnItem namedLogitem)
    in
    case privacy of
        TrU.Both    -> Log.usingLoggerName lh loggerName $ Log.logMessage severity message
        -- ^ pass to every logging scribe
        TrU.Public  -> Log.usingLoggerName lh loggerName $
            logMCond lh severity message selectSecretLogs
        -- ^ pass to logging scribes that are marked as
        -- public (LogSecurityLevel == SecretLogLevel).
        TrU.Private -> Log.usingLoggerName lh loggerName $
            logMCond lh severity message selectSecretLogs
        -- ^ pass to logging scribes that are marked as
        -- private (LogSecurityLevel == SecretLogLevel).

{- testing:

logTrace' <- setupLogging (Pos.Util.LoggerConfig.defaultInteractiveConfiguration Log.Debug) "named"
let li = publicLogItem (Log.Debug, "testing")
    ni = namedItem "Tests" li

traceWith logTrace' ni
traceWith (named $ appendName "more" logTrace') li


logTrace' <- setupLogging (Pos.Util.LoggerConfig.defaultInteractiveConfiguration Log.Debug) "named"
logDebug logTrace' "hello"
logDebug (appendName "blabla" logTrace') "hello"
-}