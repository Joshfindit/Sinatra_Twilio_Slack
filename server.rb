require "rubygems"
require "sinatra"
require "rest-client"
require 'open-uri'
require 'addressable/uri'
require 'twilio-ruby'
require 'yaml'

configFile = YAML::load_file(File.join(__dir__, '_config.yml'))

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
  set :slackSlashCommandTokenCall, configFile['slackSlashCommandTokenCall']
  set :slackSlashCommandTokenCallFrom, configFile['slackSlashCommandTokenCallFrom']
  set :twilioAccountSID, configFile['twilioAccountSID']
  set :twilioAuthToken, configFile['twilioAuthToken']
  set :twilioOutsideNumber, configFile['twilioOutsideNumber']
  set :twilioSecondOutsideNumber, configFile['twilioSecondOutsideNumber']
  set :myCurrentNumber, configFile['myCurrentNumber']
end

use Rack::TwilioWebhookAuthentication, settings.twilioAuthToken, '/Twilio_Slack/incoming' #verifies that only Twilio can post to the 'incoming' url. As per http://thinkvoice.net/twilio-sms-forwarding/

set :port, 8080
set :environment, :production

error Sinatra::NotFound do
  content_type 'text/plain'
  [404, 'Not Found']
end

def sanitize_number (string)
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


## Needs testing
def startConference(to, from, myNumber) #"to" is the recipient. myNumber is the caller #Needs testing
  begin
    @client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
    @call = @client.account.calls.create(
      :from => "+#{from}",   # From your Twilio number
      #:to => '+#{myCurrentPhoneNumber}',     # To any number
      :to => "+#{myNumber}", #to me
      :timeout => 7, #Only try me for 7 seconds
      #:record => true, #creates a second recording? Yes.
      # Fetch instructions from this URL when the call connects
      :url => "#{settings.serverBaseURL}/Twilio_Slack/startconferenceroom?room=#{to}",
#    :status_callback => "#{settings.serverBaseURL}/Twilio_Slack/callstatus?number=#{to}",
#    :status_callback_method => "POST",
#    :status_callback_event => ["initiated", "ringing", "answered", "completed"],
    )
    puts "Creating the conference by calling the first participant (#{myNumber}): #{@call.status}"
  rescue Twilio::REST::RequestError => e
    #If Twilio reports an error, rescue
    puts "Twilio reports call failed: #{e.message}"
    postMessage(params[:channel_name], "CALL command failed. Twilio reports:e #{e.message}")
  else
    #Send was successful (probably)
    #postMessage(params[:channel_name], "#{params[:user_name]} sent SMS: #{params[:text]}")
    puts "Called through Twilio successfully (to me)"
  end
end
## /Needs testing


def joinConference(to, from) #Note: the from number has to be different than the one used for the started conference
  begin
    @client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
    @call = @client.account.calls.create(
      :from => "+#{from}",   # From your Twilio number
      :to => "+#{to}", #the recipient
      :record => true, #creates a second recording?
      # Fetch instructions from this URL when the call connects
      :url => "#{settings.serverBaseURL}/Twilio_Slack/outgoingconferenceroom?room=#{to}",
      :status_callback => "#{settings.serverBaseURL}/Twilio_Slack/callstatus?number=#{to}",
      :status_callback_method => "POST",
      :status_callback_event => ["completed"]
    )
    puts "Joining #{to} to the conference: #{@call.status}"
  rescue Twilio::REST::RequestError => e
    #If Twilio reports an error, rescue
    puts "Twilio reports call failed: #{e.message}"
    postMessage(params[:channel_name], "CALL command failed. Twilio reports:e #{e.message}")
  else
    #Send was successful (probably)
    puts "Called through Twilio successfully (to #{to})"
  end
end


def conferenceInfo() #unfinished.
  #Finding information about conference rooms
  @client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
  @client.account.conferences.list({ :friendly_name => probablePhoneNumber}).each do |conference|
    puts "found conference before creation: #{conference.friendly_name}. #{conference.status}."
    #p conference
  end
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


post '/Twilio_Slack/incoming' do #Received an SMS from Twilio; post to Slack

  puts "POST request received to /Twilio_Slack/incoming : an SMS was sent to the external Twilio number"
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


post '/Twilio_Slack/outgoing' do #Sending an SMS from Slack to Twilio
#  p params

  puts "POST request recieved to /Twilio_Slack/outgoing . Time to send an SMS."

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


post '/Twilio_Slack/outgoingphonecall' do
#  p params

  puts "POST request recieved to /Twilio_Slack/outgoingphonecall. Calling the forwarding number (settings.myCurrentNumber)"
  if params[:token] == settings.slackSlashCommandTokenCall || params[:token] == settings.slackSlashCommandTokenCallFrom
    puts "channel_id: #{params[:channel_name]}"
    puts "manualNumber: #{params[:text]}"
    #    puts sanitize_number(params[:channel_name])

    # strip sms from params[:channel_name]
    if potentialPhoneNumber = sanitize_number(params[:channel_name]) #Get the outgoing number
      # Check if it's an 11 digit number
      #      puts "potentialPhoneNumber: #{potentialPhoneNumber}"
      #      puts "potentialPhoneNumber.length: #{potentialPhoneNumber.length}"
      if potentialPhoneNumber.length == 11
        probablePhoneNumber = potentialPhoneNumber
        puts "Phone number (probably) detected: #{probablePhoneNumber}"
      else
        #Send a message to the channel stating that a phone number wasn't found
        postMessage(params[:channel_name], "CALL command failed - the channel name does not contain an 11 digit number.")
        halt
      end
    end

    if params[:text] != '' #Get my number
      myPotentialPhoneNumber = params[:text]
    else
      myPotentialPhoneNumber = settings.myCurrentNumber
    end

    if myPotentialPhoneNumber.length == 11
      # Call from Twilio - my phone first
      myCurrentPhoneNumber = myPotentialPhoneNumber
      puts "Dialing #{myCurrentPhoneNumber}"
      postMessage(params[:channel_name], "Calling you at #{myCurrentPhoneNumber}.")
      startConference(probablePhoneNumber, settings.twilioSecondOutsideNumber, myCurrentPhoneNumber)

      #Wait for the channel to be created. For now, we'll just sleep
      sleep 5
      i = 0
      while i < 11 do #wait 11 seconds before trying not to do the second call. Note: Conference is marked as in-progress after 17 seconds?
                      #Turns out the call went to voicemail, which was marked as in progress. This complicates things. Timeout
        puts "Waiting. i = #{i}"
        sleep 1
        conferenceListStatus = @client.account.conferences.list({
          :status => "in-progress",
          :friendly_name => "#{probablePhoneNumber}"}).each do |conference|
          # if conference.status == "in-progress"
            puts "Found in-progress conference - calling the second number"
            postMessage(params[:channel_name], "You answered (probably). Calling the recipient at #{probablePhoneNumber}.")
            puts "Now doing joinConference(#{probablePhoneNumber}, #{settings.twilioOutsideNumber})"
            joinConference(probablePhoneNumber, settings.twilioOutsideNumber)
            postMessage("twilio-status", "Made a call between caller at #{myCurrentPhoneNumber} and recipient at #{probablePhoneNumber}.")
            i = 20
            break
          # else
            #puts conference.status
          # end
        end
        i +=1
      end
      puts "conferenceListStatus: #{conferenceListStatus}"
      # joinConference(probablePhoneNumber, settings.twilioOutsideNumber)

    else
      #Send a message to the channel stating that a phone number wasn't found
      postMessage(params[:channel_name], "CALL command failed - '#{myPotentialPhoneNumber}' number is not 11 digits. Try /callfrom")
      halt
    end

    #puts "Twiml = #{settings.serverBaseURL}/Twilio_Slack/outgoingconferenceroom?room=#{probablePhoneNumber}"
  end
  #@client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
end



post '/Twilio_Slack/startconferenceroom' do
  #p params
  #room = params[:room]
  
  twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Say>Connecting</Say><Dial><Conference record='record-from-start' beep='true' startConferenceOnEnter='true' endConferenceOnExit='true'>#{params[:room]}</Conference></Dial></Response>"

  content_type 'text/xml'

  twiml
end


post '/Twilio_Slack/outgoingconferenceroom' do
  #p params
  #room = params[:room]

  twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Say></Say><Dial><Conference record='record-from-start' beep='false' waitUrl='' startConferenceOnEnter='true' endConferenceOnExit='true'>#{params[:room]}</Conference></Dial></Response>"
  # "<?xml version='1.0' encoding='UTF-8'?><Response><Say>Connecting</Say><Dial><Conference beep='true' endConferenceOnExit='false'>#{params[:room]}</Conference></Dial></Response>"

  content_type 'text/xml'

  twiml
end


post '/Twilio_Slack/callstatus' do
  puts "Request received on /Twilio_Slack/callstatus"
  p params

#Example completed post:
##{"Called"=>"+18885551212", "ToState"=>"", "CallerCountry"=>"US",
#  "Direction"=>"inbound", "Timestamp"=>"Sun, 08 Nov 2015 18:49:31 +0000",
#  "CallbackSource"=>"call-progress-events", "CallerState"=>"NC", "ToZip"=>"",
#  "SequenceNumber"=>"0", "CallSid"=>"CA7b9df41d0dIOAd1f76fafebe844105ab4",
#  "To"=>"+18885551212", "CallerZip"=>"28301", "CallerName"=>"FAYETTEVILL  NC",
#  "ToCountry"=>"US", "ApiVersion"=>"2010-04-01", "CalledZip"=>"", "CalledCity"=>"",
#  "CallStatus"=>"completed", "Duration"=>"1", "From"=>"+19105285448", "CallDuration"=>"17",
#  "AccountSid"=>"AC7a7689e38d69622e332c0e65690c9b5e", "CalledCountry"=>"US",
#  "CallerCity"=>"FAYETTEVILLE", "Caller"=>"+19105285448", "FromCountry"=>"US",
#  "ToCity"=>"", "FromCity"=>"FAYETTEVILLE", "CalledState"=>"", "FromZip"=>"28301", "FromState"=>"NC"}

  if params[:CallStatus] == "completed"
    if params[:number] #if '?number' is specified (the recipient) post to the the correct channel
      puts "sanitize_number(params[:number]) #{sanitize_number(params[:number])}. params[:number]: #{params[:number]}"
      postMessage("sms#{sanitize_number(params[:number])}", "**New #{params[:Duration]}min recording** from #{params[:number]}.\nRecording link: #{params[:RecordingUrl]}.wav")
    else #channel not specified. must be an incoming call. Post to Twilio-status
      puts "?number not specified. must be an incoming call."
      if params[:RecordingUrl]
        postMessage("twilio-status", "**New #{params[:Duration]}min recording** from #{params[:number]} (#{params[:Caller]}, #{params[:CallerName]}).\nRecording link: #{params[:RecordingUrl]}.wav")
      else
        postMessage("twilio-status", "**incoming call at #{params[:Timestamp]} from #{params[:From]} (#{params[:CallerName]})")
      end
    end
  else
    puts "Called /callstatus with a non-'completed' status"
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