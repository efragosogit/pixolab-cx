class AgentBots::ReleaseStaleConversationsJob < ApplicationJob
  queue_as :scheduled_jobs

  # How long a conversation can sit with the bot as its owner, waiting on a reply,
  # before it gets handed to a human. A bot-owned conversation is neither "mine" nor
  # "unassigned" to a human agent (see Conversation#assignee_type), so if the bot
  # never escalates it (a failed run, or a chat that simply never qualifies as a
  # lead) it stays invisible to agents indefinitely with no other recovery path.
  TIMEOUT_MINUTES = ENV.fetch('AGENT_BOT_CONVERSATION_TIMEOUT_MINUTES', 30).to_i

  def perform
    return unless TIMEOUT_MINUTES.positive?

    stale_conversations.find_each { |conversation| release(conversation) }
  end

  private

  def stale_conversations
    Conversation.where(status: :pending)
                .where.not(assignee_agent_bot_id: nil)
                .where(assignee_id: nil)
                .where(last_activity_at: ..TIMEOUT_MINUTES.minutes.ago)
  end

  # Only release when the customer is the one waiting (last real message is incoming) --
  # if the bot already replied and the customer just went quiet, that's a normal pause,
  # not a stuck conversation.
  def release(conversation)
    last_message = conversation.messages.where(message_type: %i[incoming outgoing]).order(created_at: :desc).first
    return unless last_message&.incoming?

    conversation.update!(assignee_agent_bot_id: nil, status: :open)
    conversation.add_labels(['bot-timeout'])
    Conversations::ActivityMessageJob.perform_later(conversation, activity_message_params(conversation))
  end

  def activity_message_params(conversation)
    {
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: I18n.t('conversations.activity.agent_bot.timeout_moved_to_open', minutes: TIMEOUT_MINUTES)
    }
  end
end

AgentBots::ReleaseStaleConversationsJob.prepend_mod_with('AgentBots::ReleaseStaleConversationsJob')
