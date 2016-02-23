require "rubygems"
require "sinatra"
require "rest-client"
require 'open-uri'
require 'addressable/uri'
require 'twilio-ruby'
require 'yaml'

configFile = YAML::load_file(File.join(__dir__, 'config.yml'))

configure do
  set :serverBaseURL, configFile['serverBaseURL']
  set :slackToken, configFile['slackToken']
  set :slackBotUsername, configFile['slackBotUsername']
  set :slackPostMessageEndpoint, 'https://slack.com/api/chat.postMessage'
  set :slackCreateChannelEndpoint, 'https://slack.com/api/channels.create'
  set :slackSetChannelPurposeEndpoint, 'https://slack.com/api/channels.setPurpose'
  set :slackSlashCommandTokenSMS, configFile['slackSlashCommandTokenSMS']
  set :slackSlashCommandTokenTXT, configFile['slackSlashCommandTokenTXT']
  set :slackSlashCommandTokenS, configFile['slackSlashCommandTokenS']
  # set :slackSlashCommandTokenCall, configFile['slackSlashCommandTokenCall']
  # set :slackSlashCommandTokenCallFrom, configFile['slackSlashCommandTokenCallFrom']
  set :twilioAccountSID, configFile['twilioAccountSID']
  set :twilioAuthToken, configFile['twilioAuthToken']
  set :twilioOutsideNumber, configFile['twilioOutsideNumber']
  # set :twilioSecondOutsideNumber, configFile['twilioSecondOutsideNumber']
  set :myCurrentNumber, configFile['myCurrentNumber']
end

use Rack::TwilioWebhookAuthentication, settings.twilioAuthToken, '/Twilio_Slack/incomingsms' #verifies that only Twilio can post to the 'incomingsms' url. As per http://thinkvoice.net/twilio-sms-forwarding/

set :port, 8080
set :environment, :production

error Sinatra::NotFound do
  content_type 'text/plain'
  [404, 'Not Found']
end

def sanitize_number (string) # Returns only digits
   if sanitized = string.gsub(/[^\d]/, '') #watch out: if no gsub match, ruby freaks out
     return sanitized
   else
     return string
  end
end


def postMessage(channel, messageText)
  uri = Addressable::URI.parse(settings.slackPostMessageEndpoint)
  query = {token: settings.slackToken, channel: "##{channel}", text: messageText, username: settings.slackBotUsername}
  uri.query_values ||= {}
  uri.query_values = uri.query_values.merge(query)

  results = Net::HTTP.get(URI.parse(uri))
  puts "Message posted to Slack?: #{results['ok']}"

  return results['ok']
end


def createChannel(channel)
  uri = Addressable::URI.parse(settings.slackCreateChannelEndpoint)
  query = {token: settings.slackToken, name: "##{channel}"}
  uri.query_values ||= {}
  uri.query_values = uri.query_values.merge(query)
  if results = JSON.parse(Net::HTTP.get(URI.parse(uri)))
    puts "Channel ID: #{results['channel']['id']}. Setting purpose:"
    puts setChannelPurpose(results['channel']['id'], "SMS Conversation with: #{params[:From]} From: #{params[:FromCity].capitalize}, #{params[:FromState]}")
    #puts "From: #{params[:From]}")
    return results['ok']
  end
end


def setChannelPurpose(channelID, purpose) #Currently does not work. Vestigial anyways.
  uri = Addressable::URI.parse(settings.slackSetChannelPurposeEndpoint)
  query = {token: settings.slackToken, channel: channelID, purpose: purpose}
  uri.query_values ||= {}
  uri.query_values = uri.query_values.merge(query)

  results = JSON.parse(Net::HTTP.get(URI.parse(uri)))
  return results['ok']
end


post '/Twilio_Slack/forwardtocurrentnumber' do # No frills: Forwards the call to myCurrentNumber
  puts "received to /Twilio_Slack/forwardtocurrentnumber"
  p params

  #Note: Dial 'action' in this case will continue to record the caller even after the receiver hangs up
  puts twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Dial action='#{settings.serverBaseURL}/Twilio_Slack/voicemail' record='record-from-ringing' timeout='14'>#{settings.myCurrentNumber}</Dial></Response>"


  content_type 'text/xml'

  twiml

end


post '/Twilio_Slack/forwardtocurrentnumberwithtones' do # With frills: Forwards the call to myCurrentNumber and plays a beep sequence to let the caller know it's been put through Twilio
  puts "received to /Twilio_Slack/forwardtocurrentnumberwithtones"
  p params

  #Note: Dial 'action' in this case will continue to record the caller even after I hang up
  puts twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Dial action='#{settings.serverBaseURL}/Twilio_Slack/voicemail' record='record-from-ringing' timeout='14'><Number sendDigits='ww333'>#{settings.myCurrentNumber}</Number></Dial></Response>"

  content_type 'text/xml'
  
  twiml

end


post '/Twilio_Slack/incomingsms' do #Received an SMS from Twilio; post to Slack

  puts "POST request received to /Twilio_Slack/incomingsms : an SMS was sent to the external Twilio number"
  # Handy debug stuff: 
  # p params
  # puts "From: #{params[:From]}"
  # puts "City: #{params[:FromCity]}, #{params[:FromState]}"
  # puts "Message: #{params[:Body]}"
  # puts "From: #{params[:From]}"
  # p params[:SmsMessageSid]


  # Get the body of the message and parse it in to a channel-friendly sentence
  postMessageBody = "From: #{params[:From]}: #{params[:Body]}"

  # Sanitize the incoming number (remove all but digits)
  sanitizedNumber = sanitize_number(params[:From]).to_s
  prospectiveChannel = "sms#{sanitizedNumber}"

  #Get the list of channels, and search for an already existing one matching the prospectiveChannel
  uri = URI.parse("https://slack.com/api/channels.list?token=#{settings.slackToken}&pretty=1")
  # puts res.code #200 on success
  res = Net::HTTP.get_response(uri)
  channelsList = JSON.parse(res.body)
  # We have the channel JSON, now hash it for easy lookups
  channelsListByName = Hash[channelsList['channels'].map { |h| h.values_at('name', 'id') }]

  # Logic to determine whether to create channel or post it
  if number = channelsListByName[prospectiveChannel]
    puts "Channel was found! Posting Message!"
    res = postMessage(prospectiveChannel, postMessageBody)
    puts "postMessage results: #{res}"
  else
    puts "Channel was not found :( Creating channel! :)"
    # if create channel returns 200
    if createChannel(prospectiveChannel)
      puts "Channel created! Posting Message!"
      res = postMessage(prospectiveChannel, postMessageBody)
    else
      # freak out because we couldn't create a channel
      postMessage("twilio-status", "Could not create #{prospectiveChannel}")
    end
  end
end


post '/Twilio_Slack/outgoingsms' do #Sending an SMS from Slack to Twilio
#  p params

  puts "POST request recieved to /Twilio_Slack/outgoingsms . Time to send an SMS."

  # Check if the API key matches one that's allowed
  if params[:token] == settings.slackSlashCommandTokenSMS || params[:token] == settings.slackSlashCommandTokenTXT || params[:token] == settings.slackSlashCommandTokenS
    puts "channel_id: #{params[:channel_name]}"
    puts "text: #{params[:text]}"
    puts "sanitize_number(params[:channel_name]): #{sanitize_number(params[:channel_name])}"

    # strip sms from params[:channel_name]
    if potentialPhoneNumber = sanitize_number(params[:channel_name])
      # Check if it's an 11 digit number ("18005551221".length = 11)
      if potentialPhoneNumber.length == 11
        probablePhoneNumber = potentialPhoneNumber
        # Connect to Twilio
        @client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
        #Send the SMS
        begin
          @client.account.messages.create({
            :from => "+#{settings.twilioOutsideNumber}",
            :to => "+#{probablePhoneNumber}",
            :body => params[:text],
          })
        rescue Twilio::REST::RequestError => e
          #If Twilio reports an error, rescue
          puts "Twilio reports sms failed: #{e.message}"
          postMessage(params[:channel_name], "SMS command failed. Twilio reports:e #{e.message}")
        else
          #Send was successful (probably)
          postMessage(params[:channel_name], "#{params[:user_name]} sent SMS: #{params[:text]}")
          puts "Sms sent through Twilio successfully"
        end
      else
        #Send a message to the channel stating that a phone number wasn't found
        postMessage(params[:channel_name], "SMS command failed - the channel name does not contain an 11 digit number. Wrong channel?")
        halt
      end
    end

  else
    puts "Token from Slack doesn't match. Aborting."
    halt
  end
end


post '/Twilio_Slack/voicemail' do
  # 
  puts "Recieved request to /Twilio_Slack/voicemail"
  if params[:RecordingUrl] && params[:Digits] == "hangup"
    puts "Does have params[:RecordingUrl]"
    p params
    postMessage("twilio-status", "**New #{params[:Duration]}min recording** from #{params[:number]} (#{params[:Caller]}, #{params[:CallerName]}).\nRecording link: #{params[:RecordingUrl]}.wav")
    content_type 'text/xml'
    "<?xml version='1.0' encoding='UTF-8'?><Response><Say>Thank you, good bye</Say></Response>"
  else
    puts "Does NOT have params[:RecordingUrl]"
    p params

    twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Say>If this is urgent, call again. If it can wait, please send me an email</Say><Record/></Response>"

    content_type 'text/xml'

    twiml
  end
end