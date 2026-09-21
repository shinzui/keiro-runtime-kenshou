module Kenshou.Core.Canonical (canonicalEncode, sha256Hex) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Builder (Builder, char8, lazyByteString, toLazyByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector

canonicalEncode :: Value -> ByteString
canonicalEncode = LazyByteString.toStrict . toLazyByteString . render
  where
    render Null = "null"
    render (Bool True) = "true"
    render (Bool False) = "false"
    render (Number number) = lazyByteString (encode number)
    render (String value) = lazyByteString (encode value)
    render (Array values) = enclosed '[' ']' (fmap render (Vector.toList values))
    render (Object values) =
      enclosed
        '{'
        '}'
        [ lazyByteString (encode (Key.toText key)) <> char8 ':' <> render value
        | (key, value) <- sortOn (Text.encodeUtf8 . Key.toText . fst) (KeyMap.toList values)
        ]

    enclosed :: Char -> Char -> [Builder] -> Builder
    enclosed open close values = char8 open <> separated values <> char8 close
    separated [] = mempty
    separated (value : values) = value <> foldMap (char8 ',' <>) values

sha256Hex :: ByteString -> Text
sha256Hex = ("sha256:" <>) . Text.decodeUtf8 . Base16.encode . SHA256.hash
