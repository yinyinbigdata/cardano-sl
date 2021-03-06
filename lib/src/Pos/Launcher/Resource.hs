{-# LANGUAGE CPP            #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE Rank2Types     #-}
{-# LANGUAGE TypeOperators  #-}

-- | Resources used by node and ways to deal with them.

module Pos.Launcher.Resource
       (
         -- * Full resources
         NodeResources (..)

       , allocateNodeResources
       , releaseNodeResources
       , bracketNodeResources

         -- * Smaller resources
       , loggerBracket
       ) where

import           Universum

import           Control.Concurrent.STM (newEmptyTMVarIO, newTBQueueIO)
import           Control.Exception.Base (ErrorCall (..))
import           Data.Default (Default)
import qualified Data.Time as Time
import           Formatting (sformat, shown, (%))
import           System.IO (BufferMode (..), hClose, hSetBuffering)
import qualified System.Metrics as Metrics
import           System.Wlog (LoggerConfig (..), WithLogger, consoleActionB,
                     defaultHandleAction, logDebug, logInfo, maybeLogsDirB,
                     productionB, removeAllHandlers, setupLogging, showTidB)

import           Network.Broadcast.OutboundQueue.Types (NodeType (..))
import           Pos.Binary ()
import           Pos.Chain.Block (HasBlockConfiguration)
import           Pos.Chain.Delegation (DelegationVar, HasDlgConfiguration)
import           Pos.Chain.Ssc (SscParams, SscState, createSscContext)
import           Pos.Client.CLI.Util (readLoggerConfig)
import           Pos.Configuration
import           Pos.Context (ConnectedPeers (..), NodeContext (..),
                     StartTime (..))
import           Pos.Core (HasConfiguration, Timestamp, genesisData)
import           Pos.Core.Genesis (gdStartTime)
import           Pos.Core.Reporting (initializeMisbehaviorMetrics)
import           Pos.DB (MonadDBRead, NodeDBs)
import           Pos.DB.Block (mkSlogContext)
import           Pos.DB.Delegation (mkDelegationVar)
import           Pos.DB.Lrc (LrcContext (..), mkLrcSyncData)
import           Pos.DB.Rocks (closeNodeDBs, openNodeDBs)
import           Pos.DB.Ssc (mkSscState)
import           Pos.DB.Txp (GenericTxpLocalData (..), TxpGlobalSettings,
                     mkTxpLocalData, recordTxpMetrics)
import           Pos.DB.Update (mkUpdateContext)
import qualified Pos.DB.Update as GState
import qualified Pos.GState as GS
import           Pos.Infra.DHT.Real (KademliaParams (..))
import           Pos.Infra.Network.Types (NetworkConfig (..))
import           Pos.Infra.Shutdown.Types (ShutdownContext (..))
import           Pos.Infra.Slotting (SimpleSlottingStateVar,
                     mkSimpleSlottingStateVar)
import           Pos.Infra.Slotting.Types (SlottingData)
import           Pos.Infra.StateLock (newStateLock)
import           Pos.Infra.Util.JsonLog.Events (JsonLogConfig (..),
                     jsonLogConfigFromHandle)
import           Pos.Launcher.Mode (InitMode, InitModeContext (..), runInitMode)
import           Pos.Launcher.Param (BaseParams (..), LoggingParams (..),
                     NodeParams (..))
import           Pos.Util (bracketWithLogging, newInitFuture)

#ifdef linux_HOST_OS
import qualified System.Systemd.Daemon as Systemd
import qualified System.Wlog as Logger
#endif

----------------------------------------------------------------------------
-- Data type
----------------------------------------------------------------------------

-- | This data type contains all resources used by node.
data NodeResources ext = NodeResources
    { nrContext       :: !NodeContext
    , nrDBs           :: !NodeDBs
    , nrSscState      :: !SscState
    , nrTxpState      :: !(GenericTxpLocalData ext)
    , nrDlgState      :: !DelegationVar
    , nrJsonLogConfig :: !JsonLogConfig
    -- ^ Config for optional JSON logging.
    , nrEkgStore      :: !Metrics.Store
    }

----------------------------------------------------------------------------
-- Allocation/release/bracket
----------------------------------------------------------------------------

-- | Allocate all resources used by node. They must be released eventually.
allocateNodeResources
    :: forall ext .
       ( Default ext
       , HasConfiguration
       , HasNodeConfiguration
       , HasDlgConfiguration
       , HasBlockConfiguration
       )
    => NodeParams
    -> SscParams
    -> TxpGlobalSettings
    -> InitMode ()
    -> IO (NodeResources ext)
allocateNodeResources np@NodeParams {..} sscnp txpSettings initDB = do
    logInfo "Allocating node resources..."
    npDbPath <- case npDbPathM of
        Nothing -> do
            let dbPath = "node-db" :: FilePath
            logInfo $ sformat ("DB path not specified, defaulting to "%
                               shown) dbPath
            return dbPath
        Just dbPath -> return dbPath
    db <- openNodeDBs npRebuildDb npDbPath
    (futureLrcContext, putLrcContext) <- newInitFuture "lrcContext"
    (futureSlottingVar, putSlottingVar) <- newInitFuture "slottingVar"
    (futureSlottingContext, putSlottingContext) <- newInitFuture "slottingContext"
    let putSlotting sv sc = do
            putSlottingVar sv
            putSlottingContext sc
        initModeContext = InitModeContext
            db
            futureSlottingVar
            futureSlottingContext
            futureLrcContext
    logDebug "Opened DB, created some futures, going to run InitMode"
    runInitMode initModeContext $ do
        initDB
        logDebug "Initialized DB"

        nrEkgStore <- liftIO $ Metrics.newStore
        logDebug "Created EKG store"

        txpVar <- mkTxpLocalData -- doesn't use slotting or LRC
        let ancd =
                AllocateNodeContextData
                { ancdNodeParams = np
                , ancdSscParams = sscnp
                , ancdPutSlotting = putSlotting
                , ancdNetworkCfg = npNetworkConfig
                , ancdEkgStore = nrEkgStore
                , ancdTxpMemState = txpVar
                }
        ctx@NodeContext {..} <- allocateNodeContext ancd txpSettings nrEkgStore
        putLrcContext ncLrcContext
        logDebug "Filled LRC Context future"
        dlgVar <- mkDelegationVar
        logDebug "Created DLG var"
        sscState <- mkSscState
        logDebug "Created SSC var"
        jsonLogHandle <-
            case npJLFile of
                Nothing -> pure Nothing
                Just fp -> do
                    h <- openFile fp WriteMode
                    liftIO $ hSetBuffering h LineBuffering
                    return $ Just h
        jsonLogConfig <- maybe
            (pure JsonLogDisabled)
            jsonLogConfigFromHandle
            jsonLogHandle
        logDebug "JSON configuration initialized"

        logDebug "Finished allocating node resources!"
        return NodeResources
            { nrContext = ctx
            , nrDBs = db
            , nrSscState = sscState
            , nrTxpState = txpVar
            , nrDlgState = dlgVar
            , nrJsonLogConfig = jsonLogConfig
            , ..
            }

-- | Release all resources used by node. They must be released eventually.
releaseNodeResources ::
       NodeResources ext -> IO ()
releaseNodeResources NodeResources {..} = do
    case nrJsonLogConfig of
        JsonLogDisabled -> return ()
        JsonLogConfig mVarHandle _ -> do
            h <- takeMVar mVarHandle
            (liftIO . hClose) h
            putMVar mVarHandle h
    closeNodeDBs nrDBs
    releaseNodeContext nrContext

-- | Run computation which requires 'NodeResources' ensuring that
-- resources will be released eventually.
bracketNodeResources :: forall ext a.
      ( Default ext
      , HasConfiguration
      , HasNodeConfiguration
      , HasDlgConfiguration
      , HasBlockConfiguration
      )
    => NodeParams
    -> SscParams
    -> TxpGlobalSettings
    -> InitMode ()
    -> (HasConfiguration => NodeResources ext -> IO a)
    -> IO a
bracketNodeResources np sp txp initDB action = do
    let msg = "`NodeResources'"
    bracketWithLogging msg
            (allocateNodeResources np sp txp initDB)
            releaseNodeResources $ \nodeRes ->do
        -- Notify systemd we are fully operative
        -- FIXME this is not the place to notify.
        -- The network transport is not up yet.
        notifyReady
        action nodeRes

----------------------------------------------------------------------------
-- Logging
----------------------------------------------------------------------------

getRealLoggerConfig :: MonadIO m => LoggingParams -> m LoggerConfig
getRealLoggerConfig LoggingParams{..} = do
    let cfgBuilder = productionB
                  <> showTidB
                  <> maybeLogsDirB lpHandlerPrefix
    cfg <- readLoggerConfig lpConfigPath
    pure $ overrideConsoleLog $ cfg <> cfgBuilder
  where
    overrideConsoleLog :: LoggerConfig -> LoggerConfig
    overrideConsoleLog = case lpConsoleLog of
        Nothing    -> identity
        Just True  -> (<>) (consoleActionB defaultHandleAction)
        Just False -> (<>) (consoleActionB (\_ _ -> pass))

setupLoggers :: MonadIO m => LoggingParams -> m ()
setupLoggers params = setupLogging Nothing =<< getRealLoggerConfig params

-- | RAII for Logging.
loggerBracket :: LoggingParams -> IO a -> IO a
loggerBracket lp = bracket_ (setupLoggers lp) removeAllHandlers

----------------------------------------------------------------------------
-- NodeContext
----------------------------------------------------------------------------

data AllocateNodeContextData ext = AllocateNodeContextData
    { ancdNodeParams  :: !NodeParams
    , ancdSscParams   :: !SscParams
    , ancdPutSlotting :: (Timestamp, TVar SlottingData) -> SimpleSlottingStateVar -> InitMode ()
    , ancdNetworkCfg  :: NetworkConfig KademliaParams
    , ancdEkgStore    :: !Metrics.Store
    , ancdTxpMemState :: !(GenericTxpLocalData ext)
    }

allocateNodeContext
    :: forall ext .
      (HasConfiguration, HasNodeConfiguration, HasBlockConfiguration)
    => AllocateNodeContextData ext
    -> TxpGlobalSettings
    -> Metrics.Store
    -> InitMode NodeContext
allocateNodeContext ancd txpSettings ekgStore = do
    let AllocateNodeContextData { ancdNodeParams = np@NodeParams {..}
                                , ancdSscParams = sscnp
                                , ancdPutSlotting = putSlotting
                                , ancdNetworkCfg = networkConfig
                                , ancdEkgStore = store
                                , ancdTxpMemState = TxpLocalData {..}
                                } = ancd
    logInfo "Allocating node context..."
    ncLoggerConfig <- getRealLoggerConfig $ bpLoggingParams npBaseParams
    logDebug "Got logger config"
    ncStateLock <- newStateLock =<< GS.getTip
    logDebug "Created a StateLock"
    ncStateLockMetrics <- liftIO $ recordTxpMetrics store txpMemPool
    logDebug "Created StateLock metrics"
    lcLrcSync <- mkLrcSyncData >>= newTVarIO
    logDebug "Created LRC sync"
    ncSlottingVar <- (gdStartTime genesisData,) <$> mkSlottingVar
    logDebug "Created slotting variable"
    ncSlottingContext <- mkSimpleSlottingStateVar
    logDebug "Created slotting context"
    putSlotting ncSlottingVar ncSlottingContext
    logDebug "Filled slotting future"
    ncUserSecret <- newTVarIO $ npUserSecret
    logDebug "Created UserSecret variable"
    ncBlockRetrievalQueue <- liftIO $ newTBQueueIO blockRetrievalQueueSize
    ncRecoveryHeader <- liftIO newEmptyTMVarIO
    logDebug "Created block retrieval queue, recovery and progress headers"
    ncShutdownFlag <- newTVarIO False
    ncStartTime <- StartTime <$> liftIO Time.getCurrentTime
    ncLastKnownHeader <- newTVarIO Nothing
    logDebug "Created last known header and shutdown flag variables"
    ncUpdateContext <- mkUpdateContext
    logDebug "Created context for update"
    ncSscContext <- createSscContext sscnp
    logDebug "Created context for ssc"
    ncSlogContext <- mkSlogContext store
    logDebug "Created context for slog"
    -- TODO synchronize the NodeContext peers var with whatever system
    -- populates it.
    peersVar <- newTVarIO mempty
    logDebug "Created peersVar"
    mm <- initializeMisbehaviorMetrics ekgStore

    logDebug ("Dequeue policy to core:  " <> (show ((ncDequeuePolicy networkConfig) NodeCore)))
        `catch` \(ErrorCall msg) -> logDebug (toText msg)
    logDebug ("Dequeue policy to relay: " <> (show ((ncDequeuePolicy networkConfig) NodeRelay)))
        `catch` \(ErrorCall msg) -> logDebug (toText msg)
    logDebug ("Dequeue policy to edge: " <> (show ((ncDequeuePolicy networkConfig) NodeEdge)))
        `catch` \(ErrorCall msg) -> logDebug (toText msg)


    logDebug "Finished allocating node context!"
    let ctx =
            NodeContext
            { ncConnectedPeers = ConnectedPeers peersVar
            , ncLrcContext = LrcContext {..}
            , ncShutdownContext = ShutdownContext ncShutdownFlag
            , ncNodeParams = np
            , ncTxpGlobalSettings = txpSettings
            , ncNetworkConfig = networkConfig
            , ncMisbehaviorMetrics = Just mm
            , ..
            }
    return ctx

releaseNodeContext :: forall m . MonadIO m => NodeContext -> m ()
releaseNodeContext _ = return ()

-- Create new 'SlottingVar' using data from DB. Probably it would be
-- good to have it in 'infra', but it's complicated.
mkSlottingVar :: (MonadIO m, MonadDBRead m) => m (TVar SlottingData)
mkSlottingVar = newTVarIO =<< GState.getSlottingData

-- | Notify process manager tools like systemd the node is ready.
-- Available only on Linux for systems where `libsystemd-dev` is installed.
-- It defaults to a noop for all the other platforms.
#ifdef linux_HOST_OS
notifyReady :: (MonadIO m, WithLogger m) => m ()
notifyReady = do
    res <- liftIO Systemd.notifyReady
    case res of
        Just () -> return ()
        Nothing -> Logger.logWarning "notifyReady failed to notify systemd."
#else
notifyReady :: (WithLogger m) => m ()
notifyReady = logInfo "notifyReady: no systemd support enabled"
#endif
