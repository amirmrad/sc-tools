{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DerivingStrategies   #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE NumericUnderscores   #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns         #-}
{-| Building transactions
-}
module Convex.BuildTx(
  -- * Tx Builder
  TxBuilder(..),
  -- ** Looking at transaction inputs
  lookupIndexSpending,
  lookupIndexReference,
  lookupIndexMinted,
  lookupIndexWithdrawl,
  findIndexSpending,
  findIndexReference,
  findIndexMinted,
  findIndexWithdrawl,
  buildTx,
  buildTxWith,
  -- * Effect
  MonadBuildTx(..),
  BuildTxT(..),
  addBtx,
  runBuildTxT,
  runBuildTx,
  execBuildTxT,
  execBuildTx,
  execBuildTx',
  evalBuildTxT,

  -- * Building transactions
  addInputWithTxBody,
  addMintWithTxBody,
  addWithdrawalWithTxBody,
  addReference,
  addCollateral,
  addAuxScript,
  prependTxOut,
  addOutput,
  setScriptsValid,
  addRequiredSignature,

  -- ** Variations of @addInput@
  spendPublicKeyOutput,
  spendPlutusV1,
  spendPlutusV2,
  spendPlutusV2Ref,
  spendPlutusV2RefWithInlineDatum,
  spendPlutusV2RefWithoutInRef,
  spendPlutusV2RefWithoutInRefInlineDatum,
  spendPlutusV2InlineDatum,

  -- ** Adding outputs
  payToAddress,
  payToAddressTxOut,
  payToPublicKey,
  payToScriptHash,
  payToPlutusV1,
  payToPlutusV2,
  payToPlutusV2InlineDatum,
  payToPlutusV2Inline,
  payToPlutusV2InlineWithInlineDatum,
  payToPlutusV2InlineWithDatum,

  -- ** Staking
  addWithdrawal,
  addCertificate,
  addStakeWitness,

  -- ** Minting and burning tokens
  mintPlutusV1,
  mintPlutusV2,
  mintPlutusV2Ref,

  -- ** Utilities
  assetValue,

  -- * Minimum Ada deposit
  minAdaDeposit,
  setMinAdaDeposit,
  setMinAdaDepositAll
  ) where

import           Cardano.Api.Shelley        (Hash, NetworkId, PaymentKey,
                                             PlutusScript, PlutusScriptV1,
                                             PlutusScriptV2, ScriptData,
                                             ScriptHash, WitCtxTxIn, Witness)
import qualified Cardano.Api.Shelley        as C
import qualified Cardano.Ledger.Core        as CLedger
import           Control.Lens               (_1, _2, at, mapped, over, set,
                                             view, (&))
import qualified Control.Lens               as L
import           Control.Monad.Except       (MonadError (..))
import           Control.Monad.Reader.Class (MonadReader (..))
import qualified Control.Monad.State        as LazyState
import           Control.Monad.State.Class  (MonadState (..))
import qualified Control.Monad.State.Strict as StrictState
import           Control.Monad.Trans.Class  (MonadTrans (..))
import           Control.Monad.Trans.Except (ExceptT)
import           Control.Monad.Writer       (WriterT, execWriterT, runWriterT)
import           Control.Monad.Writer.Class (MonadWriter (..))
import qualified Convex.CardanoApi          as CC
import           Convex.Class               (MonadBlockchain (..),
                                             MonadBlockchainCardanoNodeT,
                                             MonadMockchain (..))
import qualified Convex.Lenses              as L
import           Convex.MonadLog            (MonadLog (..), MonadLogIgnoreT,
                                             MonadLogKatipT)
import           Convex.Scripts             (toScriptData)
import           Data.Functor.Identity      (Identity (..))
import           Data.List                  (nub)
import qualified Data.Map                   as Map
import           Data.Maybe                 (fromJust, fromMaybe)
import qualified Data.Set                   as Set
import qualified Plutus.V1.Ledger.Api       as Plutus

type TxBody = C.TxBodyContent C.BuildTx C.BabbageEra

{-| Look up the index of the @TxIn@ in the list of spending inputs
-}
lookupIndexSpending :: C.TxIn -> TxBody -> Maybe Int
lookupIndexSpending txi = Map.lookupIndex txi . Map.fromList . (fmap (view L._BuildTxWith) <$>) . view L.txIns

{-| Look up the index of the @TxIn@ in the list of spending inputs. Throws an error if the @TxIn@ is not present.
-}
findIndexSpending :: C.TxIn -> TxBody -> Int
findIndexSpending txi = fromJust . lookupIndexSpending txi

{-| Look up the index of the @TxIn@ in the list of reference inputs
-}
lookupIndexReference :: C.TxIn -> TxBody -> Maybe Int
lookupIndexReference txi = Set.lookupIndex txi . Set.fromList . view (L.txInsReference . L._TxInsReference)

{-| Look up the index of the @TxIn@ in the list of reference inputs. Throws an error if the @TxIn@ is not present.
-}
findIndexReference :: C.TxIn -> TxBody -> Int
findIndexReference txi = fromJust . lookupIndexReference txi

{-| Look up the index of the @PolicyId@ in the transaction mint.
Note: cardano-api represents a value as a @Map AssetId Quantity@, this is different than the on-chain representation
which is @Map CurrencySymbol (Map TokenName Quantity).
Here, we want to get the index into the on-chain map, but instead index into the cardano-api @Map CurrencySymbol Witness@.
These two indexes should be the same by construction, but it is possible to violate this invariant when building a tx.
-}
lookupIndexMinted :: C.PolicyId -> TxBody -> Maybe Int
lookupIndexMinted policy = Map.lookupIndex policy . view (L.txMintValue . L._TxMintValue .  _2)

{-| Look up the index of the @PolicyId@ in the transaction mint. Throws an error if the @PolicyId@ is not present.
-}
findIndexMinted :: C.PolicyId -> TxBody -> Int
findIndexMinted policy = fromJust . lookupIndexMinted policy

{-| Look up the index of the @StakeAddress@ in the list of withdrawls.
-}
lookupIndexWithdrawl :: C.StakeAddress -> TxBody -> Maybe Int
lookupIndexWithdrawl stakeAddress = Set.lookupIndex stakeAddress . Set.fromList . fmap (view _1) . view (L.txWithdrawals . L._TxWithdrawals)

{-| Look up the index of the @StakeAddress@ in the list of withdrawls. Throws an error if the @StakeAddress@ is not present.
-}
findIndexWithdrawl :: C.StakeAddress -> TxBody -> Int
findIndexWithdrawl stakeAddress = fromJust . lookupIndexWithdrawl stakeAddress


{-|
A function that modifies the final @TxBodyContent@, after seeing the @TxBodyContent@ of
the entire finished transaction (lazily).

Note that the result of @unTxBuilder txBody@ must not completely force the @txBody@,
or refer to itself circularly. For example, using this to construct a redeemer that contains the whole
@TransactionInputs@ map is going to loop forever.
-}
newtype TxBuilder = TxBuilder{ unTxBuilder :: TxBody -> TxBody -> TxBody }

{-| Construct the final @TxBodyContent@
-}
buildTx :: TxBuilder -> TxBody
buildTx txb = buildTxWith txb L.emptyTx

{-| Construct the final @TxBodyContent@ from the provided @TxBodyContent@
-}
buildTxWith :: TxBuilder -> TxBody -> TxBody
buildTxWith TxBuilder{unTxBuilder} initial =
  let result = unTxBuilder result initial
  in result

instance Semigroup TxBuilder where
    -- note that the order here is reversed, compared to @Data.Monoid.Endo@.
    -- This is so that @addBtx a >> addBtx b@ will result in a transaction
    -- where @a@ has been applied before @b@.
  (TxBuilder l) <> (TxBuilder r) = TxBuilder $ \k -> (r k . l k)

instance Monoid TxBuilder where
  mempty = TxBuilder $ const id

{-| An effect that collects @TxBuilder@ values for building
cardano transactions
-}
class Monad m => MonadBuildTx m where
  -- | Add a @TxBuilder@
  addTxBuilder :: TxBuilder -> m ()

instance MonadBuildTx m => MonadBuildTx (ExceptT e m) where
  addTxBuilder = lift . addTxBuilder

instance MonadBuildTx m => MonadBuildTx (StrictState.StateT e m) where
  addTxBuilder = lift . addTxBuilder

instance MonadBuildTx m => MonadBuildTx (LazyState.StateT e m) where
  addTxBuilder = lift . addTxBuilder

instance (Monoid w, MonadBuildTx m) => MonadBuildTx (WriterT w m) where
  addTxBuilder = lift . addTxBuilder

instance MonadBuildTx m => MonadBuildTx (MonadBlockchainCardanoNodeT e m) where
  addTxBuilder = lift . addTxBuilder

instance MonadBuildTx m => MonadBuildTx (MonadLogIgnoreT m) where
  addTxBuilder = lift . addTxBuilder

instance MonadBuildTx m => MonadBuildTx (MonadLogKatipT m) where
  addTxBuilder = lift . addTxBuilder

addBtx :: MonadBuildTx m => (TxBody -> TxBody) -> m ()
addBtx = addTxBuilder . TxBuilder . const

{-| Monad transformer for the @MonadBuildTx@ effect
-}
newtype BuildTxT m a = BuildTxT{unBuildTxT :: WriterT TxBuilder m a }
  deriving newtype (Functor, Applicative, Monad)

instance MonadTrans BuildTxT where
  lift = BuildTxT . lift

instance Monad m => MonadBuildTx (BuildTxT m) where
  addTxBuilder = BuildTxT . tell

instance MonadError e m => MonadError e (BuildTxT m) where
  throwError = lift . throwError
  catchError m action = BuildTxT (unBuildTxT $ catchError m action)

instance MonadReader e m => MonadReader e (BuildTxT m) where
  ask = lift ask
  local f = BuildTxT . local f . unBuildTxT

instance MonadBlockchain m => MonadBlockchain (BuildTxT m) where
  sendTx = lift . sendTx
  utxoByTxIn = lift . utxoByTxIn
  queryProtocolParameters = lift queryProtocolParameters
  queryStakeAddresses creds = lift . queryStakeAddresses creds
  queryStakePools = lift queryStakePools
  querySystemStart = lift querySystemStart
  queryEraHistory = lift queryEraHistory
  querySlotNo = lift querySlotNo
  networkId = lift networkId

instance MonadMockchain m => MonadMockchain (BuildTxT m) where
  modifySlot = lift . modifySlot
  modifyUtxo = lift . modifyUtxo
  resolveDatumHash = lift . resolveDatumHash

instance MonadState s m => MonadState s (BuildTxT m) where
  state = lift . state

instance MonadLog m => MonadLog (BuildTxT m) where
  logInfo' = lift . logInfo'
  logWarn' = lift . logWarn'
  logDebug' = lift . logDebug'

{-| Run the @BuildTxT@ monad transformer
-}
runBuildTxT :: BuildTxT m a -> m (a, TxBuilder)
runBuildTxT = runWriterT . unBuildTxT

{-| Run the @BuildTxT@ monad transformer, returning the @TxBuild@ part only
-}
execBuildTxT :: Monad m => BuildTxT m a -> m TxBuilder
execBuildTxT = execWriterT . unBuildTxT

{-| Run the @BuildTxT@ monad transformer, returnin only the result
-}
evalBuildTxT :: Monad m => BuildTxT m a -> m a
evalBuildTxT = fmap fst . runWriterT . unBuildTxT

runBuildTx :: BuildTxT Identity a -> (a, TxBuilder)
runBuildTx = runIdentity . runBuildTxT

execBuildTx :: BuildTxT Identity a -> TxBuilder
execBuildTx = runIdentity . execBuildTxT

{-| Run the @BuildTx@ action and produce a transaction body
-}
execBuildTx' :: BuildTxT Identity a -> TxBody
execBuildTx' = buildTx . runIdentity . execBuildTxT

{-| These functions allow to build the witness for an input/asset/withdrawl
by accessing the final @TxBodyContent@. To avoid an infinite loop when
constructing the witness, make sure that the witness does not depend on
itself. For example: @addInputWithTxBody txi (\body -> find (\in -> in == txi) (txInputs body))@
is going to loop.
-}
addInputWithTxBody :: MonadBuildTx m => C.TxIn -> (TxBody -> Witness WitCtxTxIn C.BabbageEra) -> m ()
addInputWithTxBody txIn f = addTxBuilder (TxBuilder $ \body -> (over L.txIns ((txIn, C.BuildTxWith $ f body) :)))

addMintWithTxBody :: MonadBuildTx m => C.PolicyId -> C.AssetName -> C.Quantity -> (TxBody -> C.ScriptWitness C.WitCtxMint C.BabbageEra) -> m ()
addMintWithTxBody policy assetName quantity f =
  let v = assetValue (C.unPolicyId policy) assetName quantity
  in addTxBuilder (TxBuilder $ \body -> (over (L.txMintValue . L._TxMintValue) (over _1 (<> v) . over _2 (Map.insert policy (f body)))))

addWithdrawalWithTxBody ::  MonadBuildTx m => C.StakeAddress -> C.Lovelace -> (TxBody -> C.Witness C.WitCtxStake C.BabbageEra) -> m ()
addWithdrawalWithTxBody address amount f =
  addTxBuilder (TxBuilder $ \body -> (over (L.txWithdrawals . L._TxWithdrawals) ((address, amount, C.BuildTxWith $ f body) :)))

{-| Spend an output locked by a public key
-}
spendPublicKeyOutput :: MonadBuildTx m => C.TxIn -> m ()
spendPublicKeyOutput txIn = do
  let wit = C.BuildTxWith (C.KeyWitness (C.KeyWitnessForSpending))
  addBtx (over L.txIns ((txIn, wit) :))

spendPlutusV1 :: forall datum redeemer m. (MonadBuildTx m, Plutus.ToData datum, Plutus.ToData redeemer) => C.TxIn -> PlutusScript PlutusScriptV1 -> datum -> redeemer -> m ()
spendPlutusV1 txIn s (toScriptData -> dat) (toScriptData -> red) =
  let wit = C.PlutusScriptWitness C.PlutusScriptV1InBabbage C.PlutusScriptV1 (C.PScript s) (C.ScriptDatumForTxIn dat) red (C.ExecutionUnits 0 0)
      wit' = C.BuildTxWith (C.ScriptWitness C.ScriptWitnessForSpending wit)
  in setScriptsValid >> addBtx (over L.txIns ((txIn, wit') :))

spendPlutusV2 :: forall datum redeemer m. (MonadBuildTx m, Plutus.ToData datum, Plutus.ToData redeemer) => C.TxIn -> PlutusScript PlutusScriptV2 -> datum -> redeemer -> m ()
spendPlutusV2 txIn s (toScriptData -> dat) (toScriptData -> red) =
  let wit = C.PlutusScriptWitness C.PlutusScriptV2InBabbage C.PlutusScriptV2 (C.PScript s) (C.ScriptDatumForTxIn dat) red (C.ExecutionUnits 0 0)
      wit' = C.BuildTxWith (C.ScriptWitness C.ScriptWitnessForSpending wit)
  in setScriptsValid >> addBtx (over L.txIns ((txIn, wit') :))

{-| Spend an output locked by a Plutus V2 validator with an inline datum
-}
spendPlutusV2InlineDatum :: forall redeemer m. (MonadBuildTx m, Plutus.ToData redeemer) => C.TxIn -> PlutusScript PlutusScriptV2 -> redeemer -> m ()
spendPlutusV2InlineDatum txIn s (toScriptData -> red) =
  let wit = C.PlutusScriptWitness C.PlutusScriptV2InBabbage C.PlutusScriptV2 (C.PScript s) C.InlineScriptDatum red (C.ExecutionUnits 0 0)
      wit' = C.BuildTxWith (C.ScriptWitness C.ScriptWitnessForSpending wit)
  in setScriptsValid >> addBtx (over L.txIns ((txIn, wit') :))

spendPlutusV2RefBase :: forall redeemer m. (MonadBuildTx m, Plutus.ToData redeemer) => C.TxIn -> C.TxIn -> Maybe C.ScriptHash -> C.ScriptDatum C.WitCtxTxIn -> (Int -> redeemer) -> m ()
spendPlutusV2RefBase txIn refTxIn sh dat red =
  let wit lkp = C.PlutusScriptWitness C.PlutusScriptV2InBabbage C.PlutusScriptV2 (C.PReferenceScript refTxIn sh) dat (toScriptData $ red $ findIndexSpending txIn lkp) (C.ExecutionUnits 0 0)
      wit' = C.BuildTxWith . C.ScriptWitness C.ScriptWitnessForSpending . wit
  in setScriptsValid >> addTxBuilder (TxBuilder $ \body -> over L.txIns ((txIn, wit' body) :))

{-| Spend an output locked by a Plutus V2 validator using the redeemer
-}
spendPlutusV2RefBaseWithInRef :: forall redeemer m. (MonadBuildTx m, Plutus.ToData redeemer) => C.TxIn -> C.TxIn -> Maybe C.ScriptHash -> C.ScriptDatum C.WitCtxTxIn -> redeemer -> m ()
spendPlutusV2RefBaseWithInRef txIn refTxIn sh dat red = spendPlutusV2RefBase txIn refTxIn sh dat (const red) >> addReference refTxIn

spendPlutusV2Ref :: forall datum redeemer m. (MonadBuildTx m, Plutus.ToData datum, Plutus.ToData redeemer) => C.TxIn -> C.TxIn -> Maybe C.ScriptHash -> datum -> redeemer -> m ()
spendPlutusV2Ref txIn refTxIn sh (toScriptData -> dat) red = spendPlutusV2RefBaseWithInRef txIn refTxIn sh (C.ScriptDatumForTxIn dat) red

{-| same as spendPlutusV2Ref but considers inline datum at the spent utxo
-}
spendPlutusV2RefWithInlineDatum :: forall redeemer m. (MonadBuildTx m, Plutus.ToData redeemer) => C.TxIn -> C.TxIn -> Maybe C.ScriptHash -> redeemer -> m ()
spendPlutusV2RefWithInlineDatum txIn refTxIn sh red = spendPlutusV2RefBaseWithInRef txIn refTxIn sh C.InlineScriptDatum red

{-| same as spendPlutusV2Ref but does not add the reference script in the reference input list
This is to cover the case whereby the reference script utxo is expected to be consumed in the same tx.
-}
spendPlutusV2RefWithoutInRef :: forall datum redeemer m. (MonadBuildTx m, Plutus.ToData datum, Plutus.ToData redeemer) => C.TxIn -> C.TxIn -> Maybe C.ScriptHash -> datum -> redeemer -> m ()
spendPlutusV2RefWithoutInRef txIn refTxIn sh (toScriptData -> dat) red = spendPlutusV2RefBase txIn refTxIn sh (C.ScriptDatumForTxIn dat) (const red)

{-| same as spendPlutusV2RefWithoutInRef but considers inline datum at the spent utxo
-}
spendPlutusV2RefWithoutInRefInlineDatum :: forall redeemer m. (MonadBuildTx m, Plutus.ToData redeemer) => C.TxIn -> C.TxIn -> Maybe C.ScriptHash -> redeemer -> m ()
spendPlutusV2RefWithoutInRefInlineDatum txIn refTxIn sh red = spendPlutusV2RefBase txIn refTxIn sh C.InlineScriptDatum (const red)

mintPlutusV1 :: forall redeemer m. (MonadBuildTx m, Plutus.ToData redeemer) => PlutusScript PlutusScriptV1 -> redeemer -> C.AssetName -> C.Quantity -> m ()
mintPlutusV1 script (toScriptData -> red) assetName quantity =
  let sh = C.hashScript (C.PlutusScript C.PlutusScriptV1 script)
      v = assetValue sh assetName quantity
      policyId = C.PolicyId sh
      wit      = C.PlutusScriptWitness C.PlutusScriptV1InBabbage C.PlutusScriptV1 (C.PScript script) (C.NoScriptDatumForMint) red (C.ExecutionUnits 0 0)
  in  setScriptsValid >> addBtx (over (L.txMintValue . L._TxMintValue) (over _1 (<> v) . over _2 (Map.insert policyId wit)))

{-| A value containing the given amount of the native asset
-}
assetValue :: ScriptHash -> C.AssetName -> C.Quantity -> C.Value
assetValue hsh assetName quantity =
  C.valueFromList [(C.AssetId (C.PolicyId hsh) assetName, quantity)]

mintPlutusV2 :: forall redeemer m. (Plutus.ToData redeemer, MonadBuildTx m) => PlutusScript PlutusScriptV2 -> redeemer -> C.AssetName -> C.Quantity -> m ()
mintPlutusV2 script (toScriptData -> red) assetName quantity =
  let sh = C.hashScript (C.PlutusScript C.PlutusScriptV2 script)
      v = assetValue sh assetName quantity
      policyId = C.PolicyId sh
      wit      = C.PlutusScriptWitness C.PlutusScriptV2InBabbage C.PlutusScriptV2 (C.PScript script) (C.NoScriptDatumForMint) red (C.ExecutionUnits 0 0)
  in  setScriptsValid >> addBtx (over (L.txMintValue . L._TxMintValue) (over _1 (<> v) . over _2 (Map.insert policyId wit)))

mintPlutusV2Ref :: forall redeemer m. (Plutus.ToData redeemer, MonadBuildTx m) => C.TxIn -> C.ScriptHash -> redeemer -> C.AssetName -> C.Quantity -> m ()
mintPlutusV2Ref refTxIn sh (toScriptData -> red) assetName quantity =
  let v = assetValue sh assetName quantity
      wit = C.PlutusScriptWitness C.PlutusScriptV2InBabbage C.PlutusScriptV2 (C.PReferenceScript refTxIn (Just sh)) (C.NoScriptDatumForMint) red (C.ExecutionUnits 0 0)
      policyId = C.PolicyId sh
  in  setScriptsValid
      >> addBtx (over (L.txMintValue . L._TxMintValue) (over _1 (<> v) . over _2 (Map.insert policyId wit)))
      >> addReference refTxIn

addCollateral :: MonadBuildTx m => C.TxIn -> m ()
addCollateral i = addBtx $ over (L.txInsCollateral . L._TxInsCollateral) ((:) i)

addReference :: MonadBuildTx m => C.TxIn -> m ()
addReference i = addBtx $ over (L.txInsReference . L._TxInsReference) ((:) i)

addAuxScript :: MonadBuildTx m => C.ScriptInEra C.BabbageEra -> m ()
addAuxScript s = addBtx (over (L.txAuxScripts . L._TxAuxScripts) ((:) s))

payToAddressTxOut :: C.AddressInEra C.BabbageEra -> C.Value -> C.TxOut C.CtxTx C.BabbageEra
payToAddressTxOut addr vl = C.TxOut addr (C.TxOutValue C.MultiAssetInBabbageEra vl) C.TxOutDatumNone C.ReferenceScriptNone

payToAddress :: MonadBuildTx m => C.AddressInEra C.BabbageEra -> C.Value -> m ()
payToAddress addr vl = addBtx $ over L.txOuts ((:) (payToAddressTxOut addr vl))

payToPublicKey :: MonadBuildTx m => NetworkId -> Hash PaymentKey -> C.Value -> m ()
payToPublicKey network pk vl =
  let val = C.TxOutValue C.MultiAssetInBabbageEra vl
      addr = C.makeShelleyAddressInEra network (C.PaymentCredentialByKey pk) C.NoStakeAddress
      txo = C.TxOut addr val C.TxOutDatumNone C.ReferenceScriptNone
  in prependTxOut txo

payToScriptHash :: MonadBuildTx m => NetworkId -> ScriptHash -> ScriptData -> C.StakeAddressReference -> C.Value -> m ()
payToScriptHash network script datum stakeAddress vl =
  let val = C.TxOutValue C.MultiAssetInBabbageEra vl
      addr = C.makeShelleyAddressInEra network (C.PaymentCredentialByScript script) stakeAddress
      dat = C.TxOutDatumInTx C.ScriptDataInBabbageEra datum
      txo = C.TxOut addr val dat C.ReferenceScriptNone
  in prependTxOut txo

payToPlutusV1 :: forall a m. (MonadBuildTx m, Plutus.ToData a) => NetworkId -> PlutusScript PlutusScriptV1 -> a -> C.StakeAddressReference -> C.Value -> m ()
payToPlutusV1 network s datum stakeRef vl =
  let sh = C.hashScript (C.PlutusScript C.PlutusScriptV1 s)
      dt = C.fromPlutusData (Plutus.toData datum)
  in payToScriptHash network sh dt stakeRef vl

payToPlutusV2 :: forall a m. (MonadBuildTx m, Plutus.ToData a) => NetworkId -> PlutusScript PlutusScriptV2 -> a -> C.StakeAddressReference -> C.Value -> m ()
payToPlutusV2 network s datum stakeRef vl =
  let sh = C.hashScript (C.PlutusScript C.PlutusScriptV2 s)
      dt = C.fromPlutusData (Plutus.toData datum)
  in payToScriptHash network sh dt stakeRef vl

payToPlutusV2InlineBase :: MonadBuildTx m => C.AddressInEra C.BabbageEra -> C.PlutusScript C.PlutusScriptV2 -> C.TxOutDatum C.CtxTx C.BabbageEra -> C.Value -> m ()
payToPlutusV2InlineBase addr script dat vl =
  let refScript = C.ReferenceScript C.ReferenceTxInsScriptsInlineDatumsInBabbageEra (C.toScriptInAnyLang $ C.PlutusScript C.PlutusScriptV2 script)
      txo = C.TxOut addr (C.TxOutValue C.MultiAssetInBabbageEra vl) dat refScript
  in prependTxOut txo

payToPlutusV2Inline :: MonadBuildTx m => C.AddressInEra C.BabbageEra -> PlutusScript PlutusScriptV2 -> C.Value -> m ()
payToPlutusV2Inline addr script vl = payToPlutusV2InlineBase addr script C.TxOutDatumNone vl

{-| same as payToPlutusV2Inline but also specify an inline datum -}
payToPlutusV2InlineWithInlineDatum :: forall a m. (MonadBuildTx m, Plutus.ToData a) => C.AddressInEra C.BabbageEra -> C.PlutusScript C.PlutusScriptV2 -> a -> C.Value -> m ()
payToPlutusV2InlineWithInlineDatum addr script datum vl =
  let dat = C.TxOutDatumInline C.ReferenceTxInsScriptsInlineDatumsInBabbageEra (toScriptData datum)
  in payToPlutusV2InlineBase addr script dat vl

{-| same as payToPlutusV2Inline but also specify a datum -}
payToPlutusV2InlineWithDatum :: forall a m. (MonadBuildTx m, Plutus.ToData a) => C.AddressInEra C.BabbageEra -> C.PlutusScript C.PlutusScriptV2 -> a -> C.Value -> m ()
payToPlutusV2InlineWithDatum addr script datum vl =
  let dat = C.TxOutDatumInTx C.ScriptDataInBabbageEra (C.fromPlutusData $ Plutus.toData datum)
  in payToPlutusV2InlineBase addr script dat vl

payToPlutusV2InlineDatum :: forall a m. (MonadBuildTx m, Plutus.ToData a) => NetworkId -> PlutusScript PlutusScriptV2 -> a -> C.StakeAddressReference -> C.Value -> m ()
payToPlutusV2InlineDatum network script datum stakeRef vl =
  let val = C.TxOutValue C.MultiAssetInBabbageEra vl
      sh  = C.hashScript (C.PlutusScript C.PlutusScriptV2 script)
      addr = C.makeShelleyAddressInEra network (C.PaymentCredentialByScript sh) stakeRef
      dat = C.TxOutDatumInline C.ReferenceTxInsScriptsInlineDatumsInBabbageEra (toScriptData datum)
      txo = C.TxOut addr val dat C.ReferenceScriptNone
  in prependTxOut txo
-- TODO: Functions for building outputs (Output -> Output)

setScriptsValid :: MonadBuildTx m => m ()
setScriptsValid = addBtx $ set L.txScriptValidity (C.TxScriptValidity C.TxScriptValiditySupportedInBabbageEra C.ScriptValid)

{-| Set the Ada component in an output's value to at least the amount needed to cover the
minimum UTxO deposit for this output
-}
setMinAdaDeposit :: CLedger.PParams (C.ShelleyLedgerEra C.BabbageEra) -> C.TxOut C.CtxTx C.BabbageEra -> C.TxOut C.CtxTx C.BabbageEra
setMinAdaDeposit params txOut =
  let minUtxo = minAdaDeposit params txOut
  in txOut & over (L._TxOut . _2 . L._TxOutValue . L._Value . at C.AdaAssetId) (maybe (Just minUtxo) (Just . max minUtxo))

{-| Calculate the minimum amount of Ada that must be locked in the given UTxO to
satisfy the ledger's minimum Ada constraint.
-}
minAdaDeposit :: CLedger.PParams (C.ShelleyLedgerEra C.BabbageEra) -> C.TxOut C.CtxTx C.BabbageEra -> C.Quantity
minAdaDeposit params txOut =
  let minAdaValue = C.Quantity 3_000_000
      txo = txOut
            -- set the Ada value to a dummy amount to ensure that it is not 0 (if it was 0, the size of the output
            -- would be smaller, causing 'calculateMinimumUTxO' to compute an amount that is a little too small)
            & over (L._TxOut . _2 . L._TxOutValue . L._Value . at C.AdaAssetId) (maybe (Just minAdaValue) (Just . max minAdaValue))
  in fromMaybe (C.Quantity 0) $ do
        k <- either (const Nothing) pure (CC.calculateMinimumUTxO txo params)
        C.Lovelace l <- C.valueToLovelace k
        pure (C.Quantity l)

{-| Apply 'setMinAdaDeposit' to all outputs
-}
setMinAdaDepositAll :: MonadBuildTx m => CLedger.PParams (C.ShelleyLedgerEra C.BabbageEra) -> m ()
setMinAdaDepositAll params = addBtx $ over (L.txOuts . mapped) (setMinAdaDeposit params)

{-| Add a public key hash to the list of required signatures.
-}
addRequiredSignature :: MonadBuildTx m => Hash PaymentKey -> m ()
addRequiredSignature sig =
  addBtx $ over (L.txExtraKeyWits . L._TxExtraKeyWitnesses) (nub . (:) sig)

{-| Add a transaction output to the start of the list of transaction outputs.
-}
prependTxOut :: MonadBuildTx m => C.TxOut C.CtxTx C.BabbageEra -> m ()
prependTxOut txOut = addBtx (over L.txOuts ((:) txOut))

{-| Add a transaction output to the end of the list of transaction outputs.
-}
addOutput :: MonadBuildTx m => C.TxOut C.CtxTx C.BabbageEra -> m ()
addOutput txOut = addBtx (over (L.txOuts . L.reversed) ((:) txOut))

{-| Add a stake rewards withdrawal to the transaction
-}
addWithdrawal :: MonadBuildTx m => C.StakeAddress -> C.Lovelace -> C.Witness C.WitCtxStake C.BabbageEra -> m ()
addWithdrawal address amount witness =
  let withdrawal = (address, amount, C.BuildTxWith witness)
  in addBtx (over (L.txWithdrawals . L._TxWithdrawals) ((:) withdrawal))

{-| Add a certificate (stake delegation, stake pool registration, etc)
to the transaction
-}
addCertificate :: MonadBuildTx m => C.Certificate -> m ()
addCertificate cert =
  addBtx (over (L.txCertificates . L._TxCertificates . _1) ((:) cert))

{-| Add a stake witness to the transaction
-}
addStakeWitness :: MonadBuildTx m => C.StakeCredential -> C.Witness C.WitCtxStake C.BabbageEra -> m ()
addStakeWitness credential witness =
  addBtx (set (L.txCertificates . L._TxCertificates . _2 . at credential) (Just witness))
