module Kenshou.Suite.Pgmq.TopicModel (matches) where

import Data.Text qualified as Text
import Pgmq.Types (RoutingKey, TopicPattern, routingKeyToText, topicPatternToText)

matches :: TopicPattern -> RoutingKey -> Bool
matches patternValue keyValue = go (Text.splitOn "." (topicPatternToText patternValue)) (Text.splitOn "." (routingKeyToText keyValue))
  where
    go [] [] = True
    go [] _ = False
    go ("#" : _) _ = True
    go ("*" : patterns) (_ : keys) = go patterns keys
    go (patternPart : patterns) (keyPart : keys) = patternPart == keyPart && go patterns keys
    go _ _ = False
