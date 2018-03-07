{-# LANGUAGE RankNTypes #-}
module Development.Build.Example.Spreadsheet where

import Data.Char
import Data.Maybe
import Data.String
import Development.Build.Compute
import Text.Read

-- | A 'Cell' is described by a pair integers: 'row' and 'column'. We provide
-- @IsString@ instance for convenience, so @"A8"@ corresponds to @Cell 8 0@.
data Cell = Cell { row :: Int, column :: Int } deriving (Eq, Ord, Show)

-- | Get the name of a 'Cell', e.g. @name (Cell 8 0) == "A8"@.
name :: Cell -> String
name (Cell r c) | c >= 0 && c < 26 = chr (c + ord 'A') : show r
                | otherwise        = show (Cell r c)

instance IsString Cell where
    fromString string = case string of
        columnChar : rowIndex -> Cell r c
            where
              r = fromMaybe fail (readMaybe rowIndex)
              c | isAsciiUpper columnChar = ord columnChar - ord 'A'
                | otherwise               = fail
        _ -> fail
      where
        fail = error $ "Cannot parse cell name " ++ string

-- | Some cells contain formulas for computing values from other cells. Formulas
-- include:
-- * 'Constant' integer values.
-- * References to cells.
-- * Simple arithmetic functions, such as 'Unary' negation and 'Binary' addition.
-- * Conditional expressions 'IfZero' @x y z@ that evaluate to @y@ if @x@ is zero
--   and to @z@ otherwise. Conditionals require dynamic dependencies to be handled
--   correctly, because their static dependencies may form cycles. Example:
--
--   A1 = IfZero B1 A2 C1
--   A2 = IfZero B1 C2 A1
--
--   Statically there is a mutual dependency between A1 and A2, but dynamically
--   there is either A1 -> A2 or A2 -> A1.
-- * Finally, there is a 'Random' formula that returns a random value in a
--   specified range @[low..high]@. This introduces non-determinism, including
--   failures when the range is empty.
data Formula = Constant Int
             | Reference Cell
             | RelativeReference Int Int
             | Unary (Int -> Int) Formula
             | Binary (Int -> Int -> Int) Formula Formula
             | IfZero Formula Formula Formula
             | Random Int Int

instance Num Formula where
    fromInteger = Constant . fromInteger
    (+)    = Binary (+)
    (-)    = Binary (-)
    (*)    = Binary (*)
    abs    = Unary abs
    signum = Unary signum

instance IsString Formula where
    fromString = Reference . fromString

-- | A short alias for 'RelativeReference'.
rel :: Int -> Int -> Formula
rel = RelativeReference

-- | A spreadsheet is a partial mapping of cells to formulas. Cells for which
-- the mapping returns @Nothing@ are inputs.
type Spreadsheet = Cell -> Maybe Formula

-- TODO: Implement 'Random'.
-- | Spreadsheet computation.
compute :: Spreadsheet -> Compute Monad Cell Int
compute spreadsheet get cell@(Cell r c) = case spreadsheet cell of
    Nothing      -> Nothing -- This is an input
    Just formula -> Just $ evaluate formula
  where
    evaluate formula = case formula of
        Constant x              -> return x
        Reference cell          -> get cell
        RelativeReference dr dc -> get (Cell (r + dr) (c + dc))
        Unary  op fx            -> op <$> evaluate fx
        Binary op fx fy         -> op <$> evaluate fx <*> evaluate fy
        IfZero fx fy fz         -> do
            x <- evaluate fx
            if x == 0 then evaluate fy else evaluate fz
        Random _ _      -> error "Random not implemented"