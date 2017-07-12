{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

-- | See https://api.slack.com/docs/message-formatting
--
module Web.Slack.MessageParser
  ( messageToHtml
  , HtmlRenderers(..)
  , defaultHtmlRenderers
  )
  where

-- base
import Control.Monad
import Data.List
import Data.Maybe
import Data.Monoid

-- megaparsec
import Text.Megaparsec

-- mtl
import Data.Functor.Identity

-- slack-web
import Web.Slack.Types

-- text
import Data.Text (Text)
import qualified Data.Text as T

newtype SlackUrl = SlackUrl { unSlackUrl :: Text }
  deriving (Show, Eq)

data SlackMsgItem
  = SlackMsgItemPlainText Text
  | SlackMsgItemBoldSection [SlackMsgItem]
  | SlackMsgItemItalicsSection [SlackMsgItem]
  | SlackMsgItemLink Text SlackUrl
  | SlackMsgItemUserLink UserId (Maybe Text)
  | SlackMsgItemInlineCodeSection Text
  | SlackMsgItemCodeSection Text
  | SlackMsgItemQuoted [SlackMsgItem]
  | SlackMsgItemEmoticon Text
  deriving (Show, Eq)

type SlackParser a = ParsecT Dec T.Text Identity a

parseMessage :: Text -> [SlackMsgItem]
parseMessage input = fromMaybe [SlackMsgItemPlainText input] $
  parseMaybe (some $ parseMessageItem True) input

parseMessageItem :: Bool -> SlackParser SlackMsgItem
parseMessageItem acceptNewlines
  = parseBoldSection
  <|> parseItalicsSection
  <|> try parseEmoticon
  <|> parseCode
  <|> parseInlineCode
  <|> parseUserLink
  <|> parseLink
  <|> parseBlockQuote
  <|> parsePlainText
  <|> parseWhitespace acceptNewlines

parsePlainText :: SlackParser SlackMsgItem
parsePlainText = SlackMsgItemPlainText . T.pack <$>
    someTill (noneOf stopChars) (void (lookAhead $ try $ oneOf stopChars)
                                   <|> lookAhead (try boldEndSymbol)
                                   <|> lookAhead (try italicsEndSymbol)
                                   <|> lookAhead (try emoticonEndSymbol)
                                   <|> lookAhead eof)
    where stopChars = [' ', '\n']

-- slack accepts bold/italics modifiers
-- only at word boundary. for instance 'my_word'
-- doesn't trigger an italics section.
parseWhitespace :: Bool -> SlackParser SlackMsgItem
parseWhitespace True =
  SlackMsgItemPlainText . T.pack <$> some (oneOf [' ', '\n'])
parseWhitespace False = SlackMsgItemPlainText . T.pack <$> some (oneOf [' '])

boldEndSymbol :: SlackParser ()
boldEndSymbol = void $ char '*' >> lookAhead wordBoundary

italicsEndSymbol :: SlackParser ()
italicsEndSymbol = void $ char '_' >> lookAhead wordBoundary

emoticonEndSymbol :: SlackParser ()
emoticonEndSymbol = void $ char ':' >> lookAhead wordBoundary

wordBoundary :: SlackParser ()
wordBoundary = void (oneOf [' ', '\n', '*', '_', ',', '`', '?', '!', ':', ';', '.']) <|> eof

parseBoldSection :: SlackParser SlackMsgItem
parseBoldSection = fmap SlackMsgItemBoldSection $
  char '*' *> someTill (parseMessageItem False) boldEndSymbol

parseItalicsSection :: SlackParser SlackMsgItem
parseItalicsSection = fmap SlackMsgItemItalicsSection $
  char '_' *> someTill (parseMessageItem False) italicsEndSymbol

parseEmoticon :: SlackParser SlackMsgItem
parseEmoticon = fmap (SlackMsgItemEmoticon . T.pack) $
  char ':' *> someTill (alphaNumChar <|> char '_' <|> char '+') emoticonEndSymbol

parseUserLink :: SlackParser SlackMsgItem
parseUserLink = do
  void (string "<@")
  userId <- UserId . T.pack <$> some (noneOf ['|', '>'])
  let linkWithoutDesc = char '>' >>
          pure (SlackMsgItemUserLink userId Nothing)
  let linkWithDesc = char '|' >>
          SlackMsgItemUserLink <$> pure userId <*> (Just <$> ((T.pack <$> some (noneOf ['>'])) <* char '>'))
  linkWithDesc <|> linkWithoutDesc

parseLink :: SlackParser SlackMsgItem
parseLink = do
  void (char '<')
  url <- SlackUrl . T.pack <$> some (noneOf ['|', '>'])
  let linkWithoutDesc = char '>' >>
          pure (SlackMsgItemLink (unSlackUrl url) url)
  let linkWithDesc = char '|' >>
          SlackMsgItemLink <$> ((T.pack <$> some (noneOf ['>'])) <* char '>') <*> pure url
  linkWithDesc <|> linkWithoutDesc

parseCode :: SlackParser SlackMsgItem
parseCode = SlackMsgItemCodeSection . T.pack <$>
  (string "```" >> manyTill anyChar (string "```"))

parseInlineCode :: SlackParser SlackMsgItem
parseInlineCode = SlackMsgItemInlineCodeSection . T.pack <$>
  (char '`' *> some (noneOf ['`']) <* char '`')

parseBlockQuote :: SlackParser SlackMsgItem
parseBlockQuote = SlackMsgItemQuoted . intercalate [SlackMsgItemPlainText "<br/>"] <$> some blockQuoteLine

blockQuoteLine :: SlackParser [SlackMsgItem]
blockQuoteLine = string "&gt;" *> optional (char ' ') *>
    manyTill (parseMessageItem False) (eof <|> void newline)

-- |
-- Convert the slack format for messages (markdown like, see
-- https://api.slack.com/docs/message-formatting ) to HTML.
messageToHtml
  :: HtmlRenderers
  -- ^ Renderers allow you to customize the message rendering.
  -- Give 'defaultHtmlRenderers' for a default implementation.
  -> (UserId -> Text)
  -- ^ A function giving a user name for a user id. You can use 'Web.Slack.getUserDesc'
  -> SlackMessageText
  -- ^ A slack message to convert to HTML
  -> Text
  -- ^ The HTML-formatted slack message
messageToHtml htmlRenderers getUserDesc =
  messageToHtml' htmlRenderers getUserDesc . parseMessage . unSlackMessageText

messageToHtml' :: HtmlRenderers -> (UserId -> Text) -> [SlackMsgItem] -> Text
messageToHtml' htmlRenderers getUserDesc = foldr ((<>) . msgItemToHtml htmlRenderers getUserDesc) ""

data HtmlRenderers
  = HtmlRenderers
  { emoticonRenderer :: Text -> Text
  }

defaultHtmlRenderers :: HtmlRenderers
defaultHtmlRenderers = HtmlRenderers
  { emoticonRenderer = \code -> ":" <> code <> ":"
  }
  
msgItemToHtml :: HtmlRenderers -> (UserId -> Text) -> SlackMsgItem -> Text
msgItemToHtml htmlRenderers@HtmlRenderers{..} getUserDesc = \case
  SlackMsgItemPlainText txt -> T.replace "\n" "<br/>" txt
  SlackMsgItemBoldSection cts ->
    "<b>" <> messageToHtml' htmlRenderers getUserDesc cts <> "</b>"
  SlackMsgItemItalicsSection cts ->
    "<i>" <> messageToHtml' htmlRenderers getUserDesc cts <> "</i>"
  SlackMsgItemLink txt url ->
    "<a href='" <> unSlackUrl url <> "'>" <> txt <> "</a>"
  SlackMsgItemUserLink userId mTxt -> "@" <> fromMaybe (getUserDesc userId) mTxt
  SlackMsgItemEmoticon code -> emoticonRenderer code
  SlackMsgItemInlineCodeSection code -> "<code>" <> code <> "</code>"
  SlackMsgItemCodeSection code -> "<pre>" <> code <> "</pre>"
  SlackMsgItemQuoted items ->
    "<blockquote>" <> messageToHtml' htmlRenderers getUserDesc items <> "</blockquote>"