# Sinatra_Twilio_Slack
Connect Twilio and Slack together using Sinatra


## The basics

1. Gather all your API keys (Slack and Twilio)
2. Set up slash commands to send to the urls
  * Primary example: `/sms` to `http://<ip>:<port>/Twilio_Slack/outgoingsms`
3. copy `config.EXAMPLE.yml` to `config.yml`
4. Add API keys and other configurations in to `config.yml`
5. `bundle install`
6. `ruby server.rb`
7. Direct Twilio to the server's endpoints

## Work in progress

* The ability to use something like `/call` to initiate a phonecall between `myCurrentNumber` and the number for the channel
* The ability to use something like `/callfrom` to initiate a phonecall between a number specified ( such as `/callfrom 18885551212` and the number for the channel)


*As a side bonus:* this script will handle Twilio voicemails at `/Twilio_Slack/voicemail`
