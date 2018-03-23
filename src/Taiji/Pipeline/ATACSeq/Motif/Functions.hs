{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
module Taiji.Pipeline.ATACSeq.Motif.Functions
    ( atacMergePeaks
    , atacFindMotifSiteAll
    , atacGetMotifSite
    ) where

import           Bio.Data.Bed                  (BED, BED3, BEDLike (..),
                                                getMotifPValue, getMotifScore,
                                                intersectBed, mergeBed,
                                                motifScan, npPeak, npPvalue,
                                                readBed, readBed', writeBed)
import           Bio.Data.Experiment
import           Bio.Motif                     hiding (score)
import           Bio.Pipeline.Instances        ()
import           Bio.Pipeline.NGS
import           Bio.Pipeline.Utils
import           Bio.Seq.IO
import           Conduit
import           Control.Lens
import           Control.Monad.IO.Class        (liftIO)
import           Control.Monad.Reader          (asks)
import           Data.Default
import           Data.Maybe                    (fromJust, fromMaybe, isJust)
import           Data.Monoid                   ((<>))
import qualified Data.Text                     as T
import           Scientific.Workflow
import           Shelly                        (fromText, mkdir_p, shelly,
                                                test_f)
import           System.FilePath               (takeDirectory)
import           System.IO
import           System.IO.Temp                (emptyTempFile)

import           Taiji.Pipeline.ATACSeq.Config

atacMergePeaks :: ATACSeqConfig config
               => [ATACSeq S (File '[] 'NarrowPeak)]
               -> WorkflowConfig config (File '[] 'Bed)
atacMergePeaks input = do
    dir <- asks _atacseq_output_dir >>= getPath
    let fls = input^..folded.replicates.folded.files
        openChromatin = dir ++ "/openChromatin.bed"
    liftIO $ do
        peaks <- mapM (readBed' . (^.location)) fls :: IO [[BED3]]
        runConduit $ mergeBed (concat peaks) .| writeBed openChromatin
        return $ location .~ openChromatin $ emptyFile

atacFindMotifSiteAll :: ATACSeqConfig config
                     => ContextData (File '[] 'Bed) [Motif]
                     -> WorkflowConfig config (File '[] 'Bed)
atacFindMotifSiteAll (ContextData openChromatin motifs) = do
    -- Generate sequence index
    genome <- asks ( fromMaybe (error "Genome fasta file was not specified!") .
        _atacseq_genome_fasta )
    seqIndex <- asks ( fromMaybe (error "Genome index file was not specified!") .
        _atacseq_genome_index )
    fileExist <- liftIO $ shelly $ test_f $ fromText $ T.pack seqIndex
    liftIO $ if fileExist
        then hPutStrLn stderr "Sequence index exists. Skipped."
        else do
            shelly $ mkdir_p $ fromText $ T.pack $ takeDirectory seqIndex
            hPutStrLn stderr "Generating sequence index"
            mkIndex [genome] seqIndex

    dir <- asks _atacseq_output_dir >>= getPath . (<> (asDir "/TFBS/"))
    liftIO $ withGenome seqIndex $ \g -> do
        output <- emptyTempFile dir "motif_sites_part.bed"
        runConduit $ (readBed (openChromatin^.location) :: ConduitT () BED3 IO ()) .|
            motifScan g motifs def p .| getMotifScore g motifs def .|
            getMotifPValue (Just (1 - p * 10)) motifs def .| writeBed output
        return $ location .~ output $ emptyFile
  where
    p = 1e-5

-- | Retrieve TFBS for each experiment
atacGetMotifSite :: ATACSeqConfig config
                 => Int -- ^ region around summit
                 -> ([File '[] 'Bed], [ATACSeq S (File '[] 'NarrowPeak)])
                 -> WorkflowConfig config [ATACSeq S (File '[] 'Bed)]
atacGetMotifSite window (tfbs, experiment) = do
    dir <- asks _atacseq_output_dir >>= getPath . (<> (asDir "/TFBS/"))
    mapM (mapFileWithDefName dir ".bed" fun) experiment
  where
    fun output fl = liftIO $ do
        peaks <- runConduit $ readBed (fl^.location) .| mapC getSummit .| sinkList
        runConduit $ (mapM_ (readBed . (^.location)) tfbs :: Source IO BED) .|
            intersectBed peaks .| writeBed output
        return $ location .~ output $ emptyFile
    getSummit pk = let c = pk^.chromStart + fromJust (pk^.npPeak)
                   in pk & chromStart .~ c - window
                         & chromEnd .~ c + window
