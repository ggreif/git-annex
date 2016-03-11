{- adjusted branch
 -
 - Copyright 2016 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.AdjustedBranch (
	Adjustment(..),
	OrigBranch,
	AdjBranch,
	originalToAdjusted,
	adjustedToOriginal,
	fromAdjustedBranch,
	enterAdjustedBranch,
	updateAdjustedBranch,
	propigateAdjustedCommits,
) where

import Annex.Common
import qualified Annex
import Git
import Git.Types
import qualified Git.Branch
import qualified Git.Ref
import qualified Git.Command
import qualified Git.Tree
import qualified Git.DiffTree
import Git.Tree (TreeItem(..))
import Git.Sha
import Git.Env
import Git.Index
import Git.FilePath
import qualified Git.LockFile
import Annex.CatFile
import Annex.Link
import Git.HashObject
import Annex.AutoMerge
import qualified Database.Keys

import qualified Data.Map as M

data Adjustment = UnlockAdjustment
	deriving (Show)

data Direction = Forward | Reverse

{- How to perform various adjustments to a TreeItem. -}
adjustTreeItem :: Adjustment -> Direction -> HashObjectHandle -> TreeItem -> Annex (Maybe TreeItem)
adjustTreeItem UnlockAdjustment Forward h ti@(TreeItem f m s)
	| toBlobType m == Just SymlinkBlob = do
		mk <- catKey s
		case mk of
			Just k -> do
				Database.Keys.addAssociatedFile k f
				Just . TreeItem f (fromBlobType FileBlob)
					<$> hashPointerFile' h k
			Nothing -> return (Just ti)
	| otherwise = return (Just ti)
adjustTreeItem UnlockAdjustment Reverse h ti@(TreeItem f m s)
	| toBlobType m /= Just SymlinkBlob = do
		mk <- catKey s
		case mk of
			Just k -> do
				absf <- inRepo $ \r -> absPath $
					fromTopFilePath f r
				linktarget <- calcRepo $ gitAnnexLink absf k
				Just . TreeItem f (fromBlobType SymlinkBlob)
					<$> hashSymlink' h linktarget
			Nothing -> return (Just ti)
	| otherwise = return (Just ti)

type OrigBranch = Branch
type AdjBranch = Branch

adjustedBranchPrefix :: String
adjustedBranchPrefix = "refs/heads/adjusted/"

serialize :: Adjustment -> String
serialize UnlockAdjustment = "unlocked"

deserialize :: String -> Maybe Adjustment
deserialize "unlocked" = Just UnlockAdjustment
deserialize _ = Nothing

originalToAdjusted :: OrigBranch -> Adjustment -> AdjBranch
originalToAdjusted orig adj = Ref $
	adjustedBranchPrefix ++ base ++ '(' : serialize adj ++ ")"
  where
	base = fromRef (Git.Ref.basename orig)

adjustedToOriginal :: AdjBranch -> Maybe (Adjustment, OrigBranch)
adjustedToOriginal b
	| adjustedBranchPrefix `isPrefixOf` bs = do
		let (base, as) = separate (== '(') (drop prefixlen bs)
		adj <- deserialize (takeWhile (/= ')') as)
		Just (adj, Git.Ref.under "refs/heads" (Ref base))
	| otherwise = Nothing
  where
	bs = fromRef b
	prefixlen = length adjustedBranchPrefix

fromAdjustedBranch :: Branch -> OrigBranch
fromAdjustedBranch b = maybe b snd (adjustedToOriginal b)

originalBranch :: Annex (Maybe OrigBranch)
originalBranch = fmap fromAdjustedBranch <$> inRepo Git.Branch.current

{- Enter an adjusted version of current branch (or, if already in an
 - adjusted version of a branch, changes the adjustment of the original
 - branch).
 -
 - Can fail, if no branch is checked out, or perhaps if staged changes
 - conflict with the adjusted branch.
 -}
enterAdjustedBranch :: Adjustment -> Annex ()
enterAdjustedBranch adj = go =<< originalBranch
  where
	go (Just origbranch) = do
		adjbranch <- preventCommits $ const $ 
			adjustBranch adj Forward origbranch
		inRepo $ Git.Command.run
			[ Param "checkout"
			, Param $ fromRef $ Git.Ref.base $ adjbranch
			]
	go Nothing = error "not on any branch!"

adjustBranch :: Adjustment -> Direction -> OrigBranch -> Annex AdjBranch
adjustBranch adj direction origbranch = do
	sha <- adjust adj direction origbranch
	inRepo $ Git.Branch.update adjbranch sha
	return adjbranch
  where
	adjbranch = originalToAdjusted origbranch adj

adjust :: Adjustment -> Direction -> Ref -> Annex Sha
adjust adj direction orig = do
	treesha <- adjustTree adj direction orig
	commitAdjustedTree treesha orig

adjustTree :: Adjustment -> Direction -> Ref -> Annex Sha
adjustTree adj direction orig = do
	h <- inRepo hashObjectStart
	let toadj = adjustTreeItem adj direction h
	treesha <- Git.Tree.adjustTree toadj [] orig =<< Annex.gitRepo
	liftIO $ hashObjectStop h
	return treesha

type CommitsPrevented = Git.LockFile.LockHandle

{- Locks git's index file, preventing git from making a commit, merge, 
 - or otherwise changing the HEAD ref while the action is run.
 -
 - Throws an IO exception if the index file is already locked.
 -}
preventCommits :: (CommitsPrevented -> Annex a) -> Annex a
preventCommits = bracket setup cleanup
  where
	setup = do
		lck <- fromRepo indexFileLock
		liftIO $ Git.LockFile.openLock lck
	cleanup = liftIO . Git.LockFile.closeLock

{- Commits a given adjusted tree, with the provided parent ref.
 -
 - This should always yield the same value, even if performed in different 
 - clones of a repo, at different times. The commit message and other
 - metadata is based on the parent.
 -}
commitAdjustedTree :: Sha -> Ref -> Annex Sha
commitAdjustedTree treesha parent = go =<< catCommit parent
  where
	go Nothing = inRepo mkcommit
	go (Just parentcommit) = inRepo $ commitWithMetaData
		(commitAuthorMetaData parentcommit)
		(commitCommitterMetaData parentcommit)
		mkcommit
	mkcommit = Git.Branch.commitTree Git.Branch.AutomaticCommit
		adjustedBranchCommitMessage [parent] treesha

adjustedBranchCommitMessage :: String
adjustedBranchCommitMessage = "git-annex adjusted branch"

{- Update the currently checked out adjusted branch, merging the provided
 - branch into it. -}
updateAdjustedBranch :: Branch -> (OrigBranch, Adjustment) -> Git.Branch.CommitMode -> Annex Bool
updateAdjustedBranch tomerge (origbranch, adj) commitmode = catchBoolIO $ do
	preventCommits $ \commitsprevented -> go commitsprevented =<< (,)
		<$> inRepo (Git.Ref.sha tomerge)
		<*> inRepo Git.Branch.current
  where
	go commitsprevented (Just mergesha, Just currbranch) =
		ifM (inRepo $ Git.Branch.changed currbranch mergesha)
			( do
				propigateAdjustedCommits' origbranch (adj, currbranch) commitsprevented
				adjustedtomerge <- adjust adj Forward mergesha
				ifM (inRepo $ Git.Branch.changed currbranch adjustedtomerge)
					( do
						liftIO $ Git.LockFile.closeLock commitsprevented
						ifM (autoMergeFrom adjustedtomerge (Just currbranch) commitmode)
							( preventCommits $ \commitsprevented' ->
								recommit commitsprevented' currbranch mergesha =<< catCommit currbranch
							, return False
							)
					, return True -- no changes to merge
					)
			, return True -- no changes to merge
			)
	go _ _ = return False
	{- Once a merge commit has been made, re-do it, removing
	 - the old version of the adjusted branch as a parent, and
	 - making the only parent be the branch that was merged in.
	 -
	 - Doing this ensures that the same commit Sha is
	 - always arrived at for a given commit from the merged in branch.
	 -}
	recommit commitsprevented currbranch parent (Just commit) = do
		commitsha <- commitAdjustedTree (commitTree commit) parent
		inRepo $ Git.Branch.update currbranch commitsha
		propigateAdjustedCommits' origbranch (adj, currbranch) commitsprevented
		return True
	recommit _ _ _ Nothing = return False

{- Check for any commits present on the adjusted branch that have not yet
 - been propigated to the orig branch, and propigate them.
 -
 - After propigating the commits back to the orig banch,
 - rebase the adjusted branch on top of the updated orig branch.
 -}
propigateAdjustedCommits :: OrigBranch -> (Adjustment, AdjBranch) -> Annex ()
propigateAdjustedCommits origbranch (adj, currbranch) = 
	preventCommits $ propigateAdjustedCommits' origbranch (adj, currbranch)

propigateAdjustedCommits' :: OrigBranch -> (Adjustment, AdjBranch) -> CommitsPrevented -> Annex ()
propigateAdjustedCommits' origbranch (adj, currbranch) _commitsprevented = do
	ov <- inRepo $ Git.Ref.sha (Git.Ref.under "refs/heads" origbranch)
	case ov of
		Just origsha -> do
			cv <- catCommit currbranch
			case cv of
				Just currcommit -> do
					h <- inRepo hashObjectStart
					v <- newcommits >>= go h origsha False
					liftIO $ hashObjectStop h
					case v of
						Left e -> do
							warning e
							return ()
						Right newparent ->
							rebase currcommit newparent
				Nothing -> return ()
		Nothing -> return ()
  where
	newcommits = inRepo $ Git.Branch.changedCommits origbranch currbranch
		-- Get commits oldest first, so they can be processed
		-- in order made.
		[Param "--reverse"]
	go _ parent _ [] = do
		inRepo $ Git.Branch.update origbranch parent
		return (Right parent)
	go h parent pastadjcommit (sha:l) = do
		mc <- catCommit sha
		case mc of
			Just c
				| commitMessage c == adjustedBranchCommitMessage ->
					go h parent True l
				| pastadjcommit -> do
					v <- reverseAdjustedCommit h parent adj (sha, c) origbranch
					case v of
						Left e -> return (Left e)
						Right commit -> go h commit pastadjcommit l
			_ -> go h parent pastadjcommit l
	rebase currcommit newparent = do
		-- Reuse the current adjusted tree,
		-- and reparent it on top of the new
		-- version of the origbranch.
		commitAdjustedTree (commitTree currcommit) newparent
			>>= inRepo . Git.Branch.update currbranch

{- Reverses an adjusted commit, and commit on top of the provided newparent,
 - yielding a commit sha.
 -
 - Adjust the tree of the newparent, changing only the files that the
 - commit changed, and reverse adjusting those changes.
 -
 - Note that the commit message, and the author and committer metadata are
 - copied over. However, any gpg signature will be lost, and any other
 - headers are not copied either. -}
reverseAdjustedCommit :: HashObjectHandle -> Sha -> Adjustment -> (Sha, Commit) -> OrigBranch -> Annex (Either String Sha)
reverseAdjustedCommit h newparent adj (csha, c) origbranch
	-- commitDiff does not support merge commits
	| length (commitParent c) > 1 = return $
		Left $ "unable to propigate merge commit " ++ show csha ++ " back to " ++ show origbranch
	| otherwise = do
		(diff, cleanup) <- inRepo (Git.DiffTree.commitDiff csha)
		let (adds, changes) = partition (\dti -> Git.DiffTree.srcsha dti == nullSha) diff
		adds' <- catMaybes <$>
			mapM (adjustTreeItem adj Reverse h) (map diffTreeToTreeItem adds)
		treesha <- Git.Tree.adjustTree (propchanges changes)
			adds' newparent
			=<< Annex.gitRepo
		void $ liftIO cleanup
		revadjcommit <- inRepo $ commitWithMetaData
			(commitAuthorMetaData c)
			(commitCommitterMetaData c) $
				Git.Branch.commitTree Git.Branch.AutomaticCommit
					(commitMessage c) [newparent] treesha
		return (Right revadjcommit)
  where
	propchanges changes ti@(TreeItem f _ _) =
		case M.lookup f m of
			Nothing -> return (Just ti) -- not changed
			Just change -> adjustTreeItem adj Reverse h change
	  where
		m = M.fromList $ map (\i@(TreeItem f' _ _) -> (f', i)) $
			map diffTreeToTreeItem changes

diffTreeToTreeItem :: Git.DiffTree.DiffTreeItem -> TreeItem
diffTreeToTreeItem dti = TreeItem
	(Git.DiffTree.file dti)
	(Git.DiffTree.dstmode dti)
	(Git.DiffTree.dstsha dti)
