{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}
module Taiji.Pipeline.ATACSeq.Functions.Motif
    ( atacMergePeaks
    , atacFindMotifSiteAll
    , atacGetMotifSite
    ) where

import           Bio.Data.Bed                  (BED, BED3, BEDLike (..),
                                                intersectBed, mergeBed,
                                                npPeak, streamBed,
                                                readBed, sinkFileBed)
import           Bio.Data.Bed.Utils  (scanMotif, mkCutoffMotif)
import           Bio.Data.Experiment
import           Bio.Motif                     hiding (score)
import           Bio.Pipeline.Instances        ()
import           Bio.Pipeline.Utils
import           Bio.Seq.IO
import           Data.Default
import qualified Data.Text                     as T
import           System.IO.Temp                (emptyTempFile)

import           Taiji.Pipeline.ATACSeq.Types
import           Taiji.Prelude

atacMergePeaks :: ATACSeqConfig config
               => [ATACSeq S (File '[] 'NarrowPeak)]
               -> ReaderT config IO (Maybe (File '[] 'Bed))
atacMergePeaks input
    | null input = return Nothing
    | otherwise = do
        dir <- asks _atacseq_output_dir >>= getPath
        let fls = input^..folded.replicates.folded.files
            openChromatin = dir ++ "/openChromatin.bed"
        liftIO $ do
            peaks <- mapM (readBed . (^.location)) fls :: IO [[BED3]]
            runResourceT $ runConduit $
                mergeBed (concat peaks) .| sinkFileBed openChromatin
            return $ Just $ location .~ openChromatin $ emptyFile

atacFindMotifSiteAll :: ATACSeqConfig config
                     => Double     -- ^ p value
                     -> (File '[] 'Bed, [Motif])
                     -> ReaderT config IO (File '[] 'Bed)
atacFindMotifSiteAll p (openChromatin, motifs) = do
    seqIndex <- getGenomeIndex 
    dir <- asks _atacseq_output_dir >>= getPath . (<> (asDir "/TFBS/"))
    liftIO $ withGenome seqIndex $ \g -> do
        output <- emptyTempFile dir "motif_sites_part.bed"
        let motifs' = map (mkCutoffMotif def p) motifs
        runResourceT $ runConduit $
            (streamBed (openChromatin^.location) :: _ _ BED3 _ _) .|
            scanMotif g motifs' .| sinkFileBed output
        return $ location .~ output $ emptyFile

-- | Retrieve TFBS for each experiment
atacGetMotifSite :: ATACSeqConfig config
                 => Int -- ^ region around summit
                 -> ([File '[] 'Bed], ATACSeq S (File '[] 'NarrowPeak))
                 -> ReaderT config IO (ATACSeq S (File '[] 'Bed))
atacGetMotifSite window (tfbs, e) = do
    dir <- asks ((<> "/TFBS") . _atacseq_output_dir) >>= getPath
    e & replicates.traversed.files %%~ ( \fl -> liftIO $ do
        let output = printf "%s/%s_rep%d.bed" dir (T.unpack $ e^.eid)
                (e^.replicates._1)
        peaks <- runResourceT $ runConduit $
            streamBed (fl^.location) .| mapC getSummit .| sinkList
        runResourceT $ runConduit $
            (mapM_ (streamBed . (^.location)) tfbs :: _ _ BED _ _) .|
            intersectBed peaks .| sinkFileBed output
        return $ location .~ output $ emptyFile
        )
  where
    getSummit pk = let c = pk^.chromStart + fromJust (pk^.npPeak)
                   in pk & chromStart .~ c - window
                         & chromEnd .~ c + window
