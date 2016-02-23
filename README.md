# Sinatra_Twilio_Slack
Connect Twilio and Slack together using Sinatra


## The basics

1. Gather all your API keys (Slack and Twilio)
2. Set up slash commands to send to the urls
  * Primary example: `/sms` to `http://<ip>:<port>/Twilio_Slack/outgoingsms`
3. copy `config.EXAMPLE.yml` to `config.yml`
4. Add API keys and other configurations in to `config.yml`
5. `bundle install`
5. `ruby server.rb`
