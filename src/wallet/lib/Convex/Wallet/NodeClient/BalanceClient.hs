{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}
{-| A node client that shows the balance of the wallet
-}
module Convex.Wallet.NodeClient.BalanceClient(
  balanceClient
  ) where

import           Cardano.Api                (BlockInMode, CardanoMode, Env)
import qualified Cardano.Api                as C
import           Control.Monad              (when)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.Trans.Maybe  (runMaybeT)
import           Convex.MonadLog            (MonadLogKatipT (..), logInfo,
                                             logInfoS)
import           Convex.NodeClient.Fold     (CatchingUp (..), catchingUp,
                                             foldClient)
import           Convex.NodeClient.Resuming (resumingClient)
import           Convex.NodeClient.Types    (PipelinedLedgerStateClient)
import           Convex.Utxos               (PrettyBalance (..),
                                             PrettyUtxoChange (..), UtxoSet,
                                             apply)
import qualified Convex.Utxos               as Utxos
import           Convex.Wallet              (Wallet)
import qualified Convex.Wallet              as Wallet
import           Convex.Wallet.WalletState  (WalletState, chainPoint, utxoSet)
import qualified Convex.Wallet.WalletState  as WalletState
import qualified Katip                      as K

balanceClient :: K.LogEnv -> K.Namespace -> FilePath -> WalletState -> Wallet -> Env -> PipelinedLedgerStateClient
balanceClient logEnv ns filePath walletState wallet env =
  resumingClient [chainPoint walletState] $ \_ ->
    foldClient
      (CatchingUpWithNode, utxoSet walletState)
      env
      (applyBlock logEnv ns filePath wallet)

{-| Apply a new block
-}
applyBlock :: K.LogEnv -> K.Namespace -> FilePath -> Wallet -> CatchingUp -> (CatchingUp, UtxoSet) -> BlockInMode CardanoMode -> IO (Maybe (CatchingUp, UtxoSet))
applyBlock logEnv ns filePath wallet c (oldC, state) block = K.runKatipContextT logEnv () ns $ runMonadLogKatipT $ runMaybeT $ do
  let change = Utxos.extract (Wallet.shelleyPaymentCredential wallet) state block
      newState = apply state change

  when (not $ Utxos.null change) $ do
    logInfo $ PrettyUtxoChange change
    logInfo $ PrettyBalance newState

  when (oldC == CatchingUpWithNode && c == CaughtUpWithNode) $
    logInfoS "Caught up with node"

  when (not $ catchingUp c) $ do
    let C.BlockInMode (C.getBlockHeader -> header) _ = block
    liftIO (WalletState.writeToFile filePath (WalletState.walletState newState header))

  pure (c, newState)