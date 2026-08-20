export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  pendingbot: {
    Tables: {
      account_deletion_log: {
        Row: {
          deleted_at: string
          id: string
          sentiment: string
        }
        Insert: {
          deleted_at?: string
          id?: string
          sentiment: string
        }
        Update: {
          deleted_at?: string
          id?: string
          sentiment?: string
        }
        Relationships: []
      }
      admin_audit: {
        Row: {
          action: string
          actor_email: string | null
          actor_id: string | null
          after: Json | null
          before: Json | null
          created_at: string
          id: string
          ip: string | null
          target_id: string | null
          target_kind: string
          user_agent: string | null
        }
        Insert: {
          action: string
          actor_email?: string | null
          actor_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          id?: string
          ip?: string | null
          target_id?: string | null
          target_kind: string
          user_agent?: string | null
        }
        Update: {
          action?: string
          actor_email?: string | null
          actor_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          id?: string
          ip?: string | null
          target_id?: string | null
          target_kind?: string
          user_agent?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "admin_audit_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      attachments: {
        Row: {
          byte_size: number
          content_sha256: string | null
          conversation_id: string | null
          created_at: string
          filename: string | null
          height: number | null
          id: string
          metadata: Json
          mime_type: string
          r2_key: string
          summarized_at: string | null
          summary: string | null
          summary_error: string | null
          summary_status: string
          tags: string[]
          thumb_r2_key: string | null
          user_id: string
          vision_model: string | null
          width: number | null
        }
        Insert: {
          byte_size: number
          content_sha256?: string | null
          conversation_id?: string | null
          created_at?: string
          filename?: string | null
          height?: number | null
          id?: string
          metadata?: Json
          mime_type: string
          r2_key: string
          summarized_at?: string | null
          summary?: string | null
          summary_error?: string | null
          summary_status?: string
          tags?: string[]
          thumb_r2_key?: string | null
          user_id: string
          vision_model?: string | null
          width?: number | null
        }
        Update: {
          byte_size?: number
          content_sha256?: string | null
          conversation_id?: string | null
          created_at?: string
          filename?: string | null
          height?: number | null
          id?: string
          metadata?: Json
          mime_type?: string
          r2_key?: string
          summarized_at?: string | null
          summary?: string | null
          summary_error?: string | null
          summary_status?: string
          tags?: string[]
          thumb_r2_key?: string | null
          user_id?: string
          vision_model?: string | null
          width?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "attachments_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log: {
        Row: {
          audio_input_tokens: number
          audio_output_tokens: number
          billing_status: string
          cache_read_tokens: number
          cache_write_tokens: number
          conversation_id: string | null
          cost_credits: number
          cost_usd: number | null
          created_at: string
          error_class: string | null
          generation_id: string | null
          id: string
          input_tokens: number
          latency_ms: number | null
          metadata: Json
          model_id: string
          output_tokens: number
          route_trace: Json | null
          status: string | null
          tag: string | null
          task_type: string
          tool_cost_usd: number | null
          total_tokens: number
          user_id: string | null
        }
        Insert: {
          audio_input_tokens?: number
          audio_output_tokens?: number
          billing_status?: string
          cache_read_tokens?: number
          cache_write_tokens?: number
          conversation_id?: string | null
          cost_credits?: number
          cost_usd?: number | null
          created_at?: string
          error_class?: string | null
          generation_id?: string | null
          id?: string
          input_tokens?: number
          latency_ms?: number | null
          metadata?: Json
          model_id: string
          output_tokens?: number
          route_trace?: Json | null
          status?: string | null
          tag?: string | null
          task_type: string
          tool_cost_usd?: number | null
          total_tokens?: number
          user_id?: string | null
        }
        Update: {
          audio_input_tokens?: number
          audio_output_tokens?: number
          billing_status?: string
          cache_read_tokens?: number
          cache_write_tokens?: number
          conversation_id?: string | null
          cost_credits?: number
          cost_usd?: number | null
          created_at?: string
          error_class?: string | null
          generation_id?: string | null
          id?: string
          input_tokens?: number
          latency_ms?: number | null
          metadata?: Json
          model_id?: string
          output_tokens?: number
          route_trace?: Json | null
          status?: string | null
          tag?: string | null
          task_type?: string
          tool_cost_usd?: number | null
          total_tokens?: number
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_log_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log_splits: {
        Row: {
          audit_log_id: string
          created_at: string
          debit_status: string
          debited_credits: number
          share_bps: number
          user_id: string
        }
        Insert: {
          audit_log_id: string
          created_at?: string
          debit_status?: string
          debited_credits?: number
          share_bps: number
          user_id: string
        }
        Update: {
          audit_log_id?: string
          created_at?: string
          debit_status?: string
          debited_credits?: number
          share_bps?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "audit_log_splits_audit_fkey"
            columns: ["audit_log_id"]
            isOneToOne: false
            referencedRelation: "audit_log"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_web_tool_calls: {
        Row: {
          audit_log_id: string
          cost_usd: number
          created_at: string
          error_class: string | null
          id: string
          kind: string
          latency_ms: number | null
          provider: string
          result_count: number | null
          status: string
          target: string
        }
        Insert: {
          audit_log_id: string
          cost_usd?: number
          created_at?: string
          error_class?: string | null
          id?: string
          kind: string
          latency_ms?: number | null
          provider: string
          result_count?: number | null
          status: string
          target: string
        }
        Update: {
          audit_log_id?: string
          cost_usd?: number
          created_at?: string
          error_class?: string | null
          id?: string
          kind?: string
          latency_ms?: number | null
          provider?: string
          result_count?: number | null
          status?: string
          target?: string
        }
        Relationships: [
          {
            foreignKeyName: "audit_web_tool_calls_audit_fkey"
            columns: ["audit_log_id"]
            isOneToOne: false
            referencedRelation: "audit_log"
            referencedColumns: ["id"]
          },
        ]
      }
      billing_config: {
        Row: {
          key: string
          updated_at: string
          value: Json
        }
        Insert: {
          key: string
          updated_at?: string
          value: Json
        }
        Update: {
          key?: string
          updated_at?: string
          value?: Json
        }
        Relationships: []
      }
      bot_code_exec_requests: {
        Row: {
          bot_id: string
          code: string
          conversation_id: string
          created_at: string
          estimated_seconds: number
          id: string
          reason: string
          responded_at: string | null
          status: string
          user_id: string
        }
        Insert: {
          bot_id: string
          code: string
          conversation_id: string
          created_at?: string
          estimated_seconds: number
          id?: string
          reason: string
          responded_at?: string | null
          status?: string
          user_id: string
        }
        Update: {
          bot_id?: string
          code?: string
          conversation_id?: string
          created_at?: string
          estimated_seconds?: number
          id?: string
          reason?: string
          responded_at?: string | null
          status?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bot_code_exec_requests_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bot_code_exec_requests_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      bot_friend_inquiries: {
        Row: {
          answer: string | null
          answered_at: string | null
          caller_bot_id: string
          caller_conversation_id: string
          created_at: string
          id: string
          question: string
          relay_conversation_id: string
          relay_outreach_message_id: string | null
          status: string
          target_user_id: string
          updated_at: string
        }
        Insert: {
          answer?: string | null
          answered_at?: string | null
          caller_bot_id: string
          caller_conversation_id: string
          created_at?: string
          id?: string
          question: string
          relay_conversation_id: string
          relay_outreach_message_id?: string | null
          status?: string
          target_user_id: string
          updated_at?: string
        }
        Update: {
          answer?: string | null
          answered_at?: string | null
          caller_bot_id?: string
          caller_conversation_id?: string
          created_at?: string
          id?: string
          question?: string
          relay_conversation_id?: string
          relay_outreach_message_id?: string | null
          status?: string
          target_user_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bot_friend_inquiries_caller_bot_id_fkey"
            columns: ["caller_bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bot_friend_inquiries_caller_conversation_id_fkey"
            columns: ["caller_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bot_friend_inquiries_relay_conversation_id_fkey"
            columns: ["relay_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bot_friend_inquiries_relay_outreach_message_id_fkey"
            columns: ["relay_outreach_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
        ]
      }
      bot_invite_links: {
        Row: {
          bot_id: string
          created_at: string
          expires_at: string
          inviter_user_id: string
          revoked_at: string | null
          token: string
        }
        Insert: {
          bot_id: string
          created_at?: string
          expires_at?: string
          inviter_user_id: string
          revoked_at?: string | null
          token: string
        }
        Update: {
          bot_id?: string
          created_at?: string
          expires_at?: string
          inviter_user_id?: string
          revoked_at?: string | null
          token?: string
        }
        Relationships: [
          {
            foreignKeyName: "bot_invite_links_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
        ]
      }
      bot_invites: {
        Row: {
          bot_id: string
          invited_at: string
          user_id: string
        }
        Insert: {
          bot_id: string
          invited_at?: string
          user_id: string
        }
        Update: {
          bot_id?: string
          invited_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bot_invites_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
        ]
      }
      bot_lookbacks: {
        Row: {
          active: boolean
          body_md: string
          bot_id: string
          conversation_id: string
          created_at: string
          id: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          body_md: string
          bot_id: string
          conversation_id: string
          created_at?: string
          id?: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          body_md?: string
          bot_id?: string
          conversation_id?: string
          created_at?: string
          id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bot_lookbacks_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bot_lookbacks_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      bot_user_lookback_counter: {
        Row: {
          bot_id: string
          rounds_since_last: number
          updated_at: string
          user_id: string
        }
        Insert: {
          bot_id: string
          rounds_since_last?: number
          updated_at?: string
          user_id: string
        }
        Update: {
          bot_id?: string
          rounds_since_last?: number
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bot_user_lookback_counter_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
        ]
      }
      bots: {
        Row: {
          config: Json
          created_at: string
          creator_id: string | null
          display_name: string
          id: string
          is_active: boolean
          model_id: string
          model_provider: string | null
          output_mode: string
          responsible_subject_id: string | null
          slug: string
          tz: string | null
          updated_at: string
          visibility: string
          voice_call_enabled: boolean
        }
        Insert: {
          config?: Json
          created_at?: string
          creator_id?: string | null
          display_name: string
          id?: string
          is_active?: boolean
          model_id: string
          model_provider?: string | null
          output_mode?: string
          responsible_subject_id?: string | null
          slug: string
          tz?: string | null
          updated_at?: string
          visibility?: string
          voice_call_enabled?: boolean
        }
        Update: {
          config?: Json
          created_at?: string
          creator_id?: string | null
          display_name?: string
          id?: string
          is_active?: boolean
          model_id?: string
          model_provider?: string | null
          output_mode?: string
          responsible_subject_id?: string | null
          slug?: string
          tz?: string | null
          updated_at?: string
          visibility?: string
          voice_call_enabled?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "bots_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bots_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      conversation_group_meta: {
        Row: {
          avatar_url: string | null
          conversation_id: string
          created_at: string
          created_by: string | null
          join_policy: Database["pendingbot"]["Enums"]["group_join_policy"]
          max_members: number
          router_model_slug: string | null
          title: string | null
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          conversation_id: string
          created_at?: string
          created_by?: string | null
          join_policy?: Database["pendingbot"]["Enums"]["group_join_policy"]
          max_members?: number
          router_model_slug?: string | null
          title?: string | null
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          conversation_id?: string
          created_at?: string
          created_by?: string | null
          join_policy?: Database["pendingbot"]["Enums"]["group_join_policy"]
          max_members?: number
          router_model_slug?: string | null
          title?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "conversation_group_meta_conv_fkey"
            columns: ["conversation_id"]
            isOneToOne: true
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      conversation_participants: {
        Row: {
          conversation_id: string
          invited_by: string | null
          joined_at: string
          last_read_message_id: string | null
          last_read_message_seq: number | null
          muted: boolean
          nickname: string | null
          participant_id: string
          participant_type: string
          role: string
        }
        Insert: {
          conversation_id: string
          invited_by?: string | null
          joined_at?: string
          last_read_message_id?: string | null
          last_read_message_seq?: number | null
          muted?: boolean
          nickname?: string | null
          participant_id: string
          participant_type: string
          role?: string
        }
        Update: {
          conversation_id?: string
          invited_by?: string | null
          joined_at?: string
          last_read_message_id?: string | null
          last_read_message_seq?: number | null
          muted?: boolean
          nickname?: string | null
          participant_id?: string
          participant_type?: string
          role?: string
        }
        Relationships: [
          {
            foreignKeyName: "conversation_participants_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      conversations: {
        Row: {
          bot_id: string | null
          conversation_type: string
          created_at: string
          current_model_provider: string | null
          current_model_slug: string | null
          feature: string
          id: string
          last_turn_status: string | null
          message_seq_counter: number
          metadata: Json
          model_revealed: boolean
          parent_message_id: string | null
          random_model_config: Json | null
          responsible_subject_id: string | null
          round_count: number
          spawner_bot_id: string | null
          title: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          bot_id?: string | null
          conversation_type?: string
          created_at?: string
          current_model_provider?: string | null
          current_model_slug?: string | null
          feature?: string
          id?: string
          last_turn_status?: string | null
          message_seq_counter?: number
          metadata?: Json
          model_revealed?: boolean
          parent_message_id?: string | null
          random_model_config?: Json | null
          responsible_subject_id?: string | null
          round_count?: number
          spawner_bot_id?: string | null
          title?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          bot_id?: string | null
          conversation_type?: string
          created_at?: string
          current_model_provider?: string | null
          current_model_slug?: string | null
          feature?: string
          id?: string
          last_turn_status?: string | null
          message_seq_counter?: number
          metadata?: Json
          model_revealed?: boolean
          parent_message_id?: string | null
          random_model_config?: Json | null
          responsible_subject_id?: string | null
          round_count?: number
          spawner_bot_id?: string | null
          title?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "conversations_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "conversations_parent_message_id_fkey"
            columns: ["parent_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "conversations_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "conversations_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "conversations_spawner_bot_id_fkey"
            columns: ["spawner_bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
        ]
      }
      crew_announcement_mentions: {
        Row: {
          announcement_id: string
          created_at: string
          crew_conversation_id: string
          id: string
          responsible_subject_id: string
          target_kind: string
          target_member_id: string | null
          target_session_id: string | null
        }
        Insert: {
          announcement_id: string
          created_at?: string
          crew_conversation_id: string
          id?: string
          responsible_subject_id: string
          target_kind: string
          target_member_id?: string | null
          target_session_id?: string | null
        }
        Update: {
          announcement_id?: string
          created_at?: string
          crew_conversation_id?: string
          id?: string
          responsible_subject_id?: string
          target_kind?: string
          target_member_id?: string | null
          target_session_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "crew_announcement_mentions_announcement_id_fkey"
            columns: ["announcement_id"]
            isOneToOne: false
            referencedRelation: "crew_announcements"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcement_mentions_crew_conversation_id_fkey"
            columns: ["crew_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcement_mentions_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcement_mentions_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcement_mentions_target_member_id_fkey"
            columns: ["target_member_id"]
            isOneToOne: false
            referencedRelation: "temporary_group_members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcement_mentions_target_session_id_fkey"
            columns: ["target_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      crew_announcements: {
        Row: {
          board_visible: boolean
          created_at: string
          created_by_user_id: string | null
          crew_conversation_id: string
          id: string
          message_kind: string
          payload: Json
          recipient_mode: string
          responsible_subject_id: string
          sender_kind: string
          sender_member_id: string | null
          sender_session_id: string | null
          source_message_id: string | null
          summary: string
        }
        Insert: {
          board_visible?: boolean
          created_at?: string
          created_by_user_id?: string | null
          crew_conversation_id: string
          id?: string
          message_kind?: string
          payload?: Json
          recipient_mode?: string
          responsible_subject_id: string
          sender_kind: string
          sender_member_id?: string | null
          sender_session_id?: string | null
          source_message_id?: string | null
          summary: string
        }
        Update: {
          board_visible?: boolean
          created_at?: string
          created_by_user_id?: string | null
          crew_conversation_id?: string
          id?: string
          message_kind?: string
          payload?: Json
          recipient_mode?: string
          responsible_subject_id?: string
          sender_kind?: string
          sender_member_id?: string | null
          sender_session_id?: string | null
          source_message_id?: string | null
          summary?: string
        }
        Relationships: [
          {
            foreignKeyName: "crew_announcements_crew_conversation_id_fkey"
            columns: ["crew_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcements_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcements_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcements_sender_member_id_fkey"
            columns: ["sender_member_id"]
            isOneToOne: false
            referencedRelation: "temporary_group_members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcements_sender_session_id_fkey"
            columns: ["sender_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_announcements_source_message_id_fkey"
            columns: ["source_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
        ]
      }
      crew_parent_links: {
        Row: {
          child_crew_id: string
          child_share_bps: number
          confirmed_at: string | null
          created_at: string
          created_by_bot_id: string | null
          created_by_kind: string
          created_by_user_id: string | null
          id: string
          link_kind: string
          parent_crew_id: string
          requires_human_confirmation: boolean
          responsibility_mode: string
        }
        Insert: {
          child_crew_id: string
          child_share_bps: number
          confirmed_at?: string | null
          created_at?: string
          created_by_bot_id?: string | null
          created_by_kind: string
          created_by_user_id?: string | null
          id?: string
          link_kind?: string
          parent_crew_id: string
          requires_human_confirmation?: boolean
          responsibility_mode?: string
        }
        Update: {
          child_crew_id?: string
          child_share_bps?: number
          confirmed_at?: string | null
          created_at?: string
          created_by_bot_id?: string | null
          created_by_kind?: string
          created_by_user_id?: string | null
          id?: string
          link_kind?: string
          parent_crew_id?: string
          requires_human_confirmation?: boolean
          responsibility_mode?: string
        }
        Relationships: [
          {
            foreignKeyName: "crew_parent_links_child_crew_id_fkey"
            columns: ["child_crew_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_parent_links_created_by_bot_id_fkey"
            columns: ["created_by_bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_parent_links_parent_crew_id_fkey"
            columns: ["parent_crew_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      crew_pending_share_changes: {
        Row: {
          approvals: Json
          created_at: string
          crew_id: string
          decided_at: string | null
          id: string
          proposal_payload: Json
          proposed_by: string | null
          requires_subject_approvals: string[]
          status: string
        }
        Insert: {
          approvals?: Json
          created_at?: string
          crew_id: string
          decided_at?: string | null
          id?: string
          proposal_payload: Json
          proposed_by?: string | null
          requires_subject_approvals: string[]
          status?: string
        }
        Update: {
          approvals?: Json
          created_at?: string
          crew_id?: string
          decided_at?: string | null
          id?: string
          proposal_payload?: Json
          proposed_by?: string | null
          requires_subject_approvals?: string[]
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "crew_pending_share_changes_crew_id_fkey"
            columns: ["crew_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      crew_responsibility_shares: {
        Row: {
          created_at: string
          crew_conversation_id: string
          is_tiebreaker: boolean
          share_bps: number
          source: string
          subject_id: string
        }
        Insert: {
          created_at?: string
          crew_conversation_id: string
          is_tiebreaker?: boolean
          share_bps: number
          source?: string
          subject_id: string
        }
        Update: {
          created_at?: string
          crew_conversation_id?: string
          is_tiebreaker?: boolean
          share_bps?: number
          source?: string
          subject_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "crew_responsibility_shares_crew_conversation_id_fkey"
            columns: ["crew_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_responsibility_shares_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_responsibility_shares_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      crew_sessions: {
        Row: {
          assigned_to_member_id: string | null
          created_at: string
          crew_conversation_id: string
          final_result_message_id: string | null
          finished_at: string | null
          id: string
          initiating_member_id: string | null
          last_context_cursor: string | null
          permission_mode_override: string | null
          progress_summary: string | null
          responsible_subject_id: string
          runner_host_id: string | null
          runner_kind: string
          started_at: string | null
          status: string
          task_brief: string
          updated_at: string
        }
        Insert: {
          assigned_to_member_id?: string | null
          created_at?: string
          crew_conversation_id: string
          final_result_message_id?: string | null
          finished_at?: string | null
          id?: string
          initiating_member_id?: string | null
          last_context_cursor?: string | null
          permission_mode_override?: string | null
          progress_summary?: string | null
          responsible_subject_id: string
          runner_host_id?: string | null
          runner_kind: string
          started_at?: string | null
          status?: string
          task_brief: string
          updated_at?: string
        }
        Update: {
          assigned_to_member_id?: string | null
          created_at?: string
          crew_conversation_id?: string
          final_result_message_id?: string | null
          finished_at?: string | null
          id?: string
          initiating_member_id?: string | null
          last_context_cursor?: string | null
          permission_mode_override?: string | null
          progress_summary?: string | null
          responsible_subject_id?: string
          runner_host_id?: string | null
          runner_kind?: string
          started_at?: string | null
          status?: string
          task_brief?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "crew_sessions_assigned_to_member_id_fkey"
            columns: ["assigned_to_member_id"]
            isOneToOne: false
            referencedRelation: "temporary_group_members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_sessions_crew_conversation_id_fkey"
            columns: ["crew_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_sessions_final_result_message_id_fkey"
            columns: ["final_result_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_sessions_initiating_member_id_fkey"
            columns: ["initiating_member_id"]
            isOneToOne: false
            referencedRelation: "temporary_group_members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_sessions_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_sessions_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "crew_sessions_runner_host_fkey"
            columns: ["runner_host_id"]
            isOneToOne: false
            referencedRelation: "runner_hosts"
            referencedColumns: ["id"]
          },
        ]
      }
      device_tokens: {
        Row: {
          created_at: string
          endpoint: string | null
          id: string
          is_active: boolean
          kind: string
          last_used_at: string | null
          metadata: Json
          platform: string
          token: string
          user_id: string
        }
        Insert: {
          created_at?: string
          endpoint?: string | null
          id?: string
          is_active?: boolean
          kind?: string
          last_used_at?: string | null
          metadata?: Json
          platform: string
          token: string
          user_id: string
        }
        Update: {
          created_at?: string
          endpoint?: string | null
          id?: string
          is_active?: boolean
          kind?: string
          last_used_at?: string | null
          metadata?: Json
          platform?: string
          token?: string
          user_id?: string
        }
        Relationships: []
      }
      disposable_email_domains: {
        Row: {
          added_at: string
          domain: string
          note: string | null
        }
        Insert: {
          added_at?: string
          domain: string
          note?: string | null
        }
        Update: {
          added_at?: string
          domain?: string
          note?: string | null
        }
        Relationships: []
      }
      envelope_runs: {
        Row: {
          author_user_id: string | null
          body_md: string | null
          bot_id: string | null
          conversation_id: string
          cost_budget_usd: number | null
          cost_used_usd: number
          created_at: string
          finished_at: string | null
          id: string
          kind: string
          progress: Json
          settings: Json | null
          started_at: string | null
          status: string
          summary: string | null
          title: string | null
          trigger: string | null
          turns: Json
          updated_at: string
          user_id: string
        }
        Insert: {
          author_user_id?: string | null
          body_md?: string | null
          bot_id?: string | null
          conversation_id: string
          cost_budget_usd?: number | null
          cost_used_usd?: number
          created_at?: string
          finished_at?: string | null
          id?: string
          kind?: string
          progress?: Json
          settings?: Json | null
          started_at?: string | null
          status?: string
          summary?: string | null
          title?: string | null
          trigger?: string | null
          turns?: Json
          updated_at?: string
          user_id: string
        }
        Update: {
          author_user_id?: string | null
          body_md?: string | null
          bot_id?: string | null
          conversation_id?: string
          cost_budget_usd?: number | null
          cost_used_usd?: number
          created_at?: string
          finished_at?: string | null
          id?: string
          kind?: string
          progress?: Json
          settings?: Json | null
          started_at?: string | null
          status?: string
          summary?: string | null
          title?: string | null
          trigger?: string | null
          turns?: Json
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "envelope_runs_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "envelope_runs_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      family_sso_credentials: {
        Row: {
          created_at: string
          device_name: string
          expires_at: string
          id: string
          last_used_at: string | null
          revoked_at: string | null
          status: string
          token_hash: string
          user_id: string
        }
        Insert: {
          created_at?: string
          device_name: string
          expires_at?: string
          id?: string
          last_used_at?: string | null
          revoked_at?: string | null
          status?: string
          token_hash: string
          user_id: string
        }
        Update: {
          created_at?: string
          device_name?: string
          expires_at?: string
          id?: string
          last_used_at?: string | null
          revoked_at?: string | null
          status?: string
          token_hash?: string
          user_id?: string
        }
        Relationships: []
      }
      friend_requests: {
        Row: {
          created_at: string
          from_user_id: string
          id: string
          message: string | null
          remark_for_contact: string | null
          responded_at: string | null
          status: string
          to_user_id: string
          updated_at: string
          via_email: string | null
          via_handle_id: string | null
        }
        Insert: {
          created_at?: string
          from_user_id: string
          id?: string
          message?: string | null
          remark_for_contact?: string | null
          responded_at?: string | null
          status?: string
          to_user_id: string
          updated_at?: string
          via_email?: string | null
          via_handle_id?: string | null
        }
        Update: {
          created_at?: string
          from_user_id?: string
          id?: string
          message?: string | null
          remark_for_contact?: string | null
          responded_at?: string | null
          status?: string
          to_user_id?: string
          updated_at?: string
          via_email?: string | null
          via_handle_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "friend_requests_via_handle_fk"
            columns: ["via_handle_id"]
            isOneToOne: false
            referencedRelation: "user_handles"
            referencedColumns: ["id"]
          },
        ]
      }
      group_bot_descriptions: {
        Row: {
          bot_id: string
          conversation_id: string
          description: string
          revision_count: number
          updated_at: string
        }
        Insert: {
          bot_id: string
          conversation_id: string
          description: string
          revision_count?: number
          updated_at?: string
        }
        Update: {
          bot_id?: string
          conversation_id?: string
          description?: string
          revision_count?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_bot_descriptions_bot_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_bot_descriptions_conv_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      group_continue_requests: {
        Row: {
          conversation_id: string
          decided_at: string | null
          decided_by: string | null
          decision_message_id: string | null
          id: string
          pending_bot_ids: string[]
          prompt_message_id: string | null
          requested_at: string
          status: Database["pendingbot"]["Enums"]["continue_request_status"]
        }
        Insert: {
          conversation_id: string
          decided_at?: string | null
          decided_by?: string | null
          decision_message_id?: string | null
          id?: string
          pending_bot_ids: string[]
          prompt_message_id?: string | null
          requested_at?: string
          status?: Database["pendingbot"]["Enums"]["continue_request_status"]
        }
        Update: {
          conversation_id?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_message_id?: string | null
          id?: string
          pending_bot_ids?: string[]
          prompt_message_id?: string | null
          requested_at?: string
          status?: Database["pendingbot"]["Enums"]["continue_request_status"]
        }
        Relationships: [
          {
            foreignKeyName: "group_continue_requests_conv_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_continue_requests_decision_msg_fkey"
            columns: ["decision_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_continue_requests_prompt_msg_fkey"
            columns: ["prompt_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
        ]
      }
      group_contributions: {
        Row: {
          contributed_pnc_micros: number
          contributor_user_id: string
          created_at: string
          id: string
          refunded_at: string | null
          share_index_at_join: number
          source_pack_id: string | null
          status: string
          subject_id: string
        }
        Insert: {
          contributed_pnc_micros: number
          contributor_user_id: string
          created_at?: string
          id?: string
          refunded_at?: string | null
          share_index_at_join: number
          source_pack_id?: string | null
          status?: string
          subject_id: string
        }
        Update: {
          contributed_pnc_micros?: number
          contributor_user_id?: string
          created_at?: string
          id?: string
          refunded_at?: string | null
          share_index_at_join?: number
          source_pack_id?: string | null
          status?: string
          subject_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_contributions_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_contributions_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      group_invite_links: {
        Row: {
          conversation_id: string
          created_at: string
          expires_at: string
          inviter_user_id: string
          revoked_at: string | null
          token: string
        }
        Insert: {
          conversation_id: string
          created_at?: string
          expires_at?: string
          inviter_user_id: string
          revoked_at?: string | null
          token: string
        }
        Update: {
          conversation_id?: string
          created_at?: string
          expires_at?: string
          inviter_user_id?: string
          revoked_at?: string | null
          token?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_invite_links_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      group_join_handles: {
        Row: {
          conversation_id: string
          created_at: string
          enabled: boolean
          handle_type: string
          id: string
          value: string
        }
        Insert: {
          conversation_id: string
          created_at?: string
          enabled?: boolean
          handle_type: string
          id?: string
          value: string
        }
        Update: {
          conversation_id?: string
          created_at?: string
          enabled?: boolean
          handle_type?: string
          id?: string
          value?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_join_handles_conv_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      group_join_requests: {
        Row: {
          conversation_id: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          id: string
          invited_by: string | null
          message: string | null
          requester_id: string
          status: Database["pendingbot"]["Enums"]["join_request_status"]
          via_handle_id: string | null
        }
        Insert: {
          conversation_id: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          id?: string
          invited_by?: string | null
          message?: string | null
          requester_id: string
          status?: Database["pendingbot"]["Enums"]["join_request_status"]
          via_handle_id?: string | null
        }
        Update: {
          conversation_id?: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          id?: string
          invited_by?: string | null
          message?: string | null
          requester_id?: string
          status?: Database["pendingbot"]["Enums"]["join_request_status"]
          via_handle_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "group_join_requests_conv_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_join_requests_handle_fkey"
            columns: ["via_handle_id"]
            isOneToOne: false
            referencedRelation: "group_join_handles"
            referencedColumns: ["id"]
          },
        ]
      }
      group_member_invitations: {
        Row: {
          conversation_id: string
          created_at: string
          decided_at: string | null
          id: string
          invitee_id: string
          inviter_id: string
          status: Database["pendingbot"]["Enums"]["join_request_status"]
        }
        Insert: {
          conversation_id: string
          created_at?: string
          decided_at?: string | null
          id?: string
          invitee_id: string
          inviter_id: string
          status?: Database["pendingbot"]["Enums"]["join_request_status"]
        }
        Update: {
          conversation_id?: string
          created_at?: string
          decided_at?: string | null
          id?: string
          invitee_id?: string
          inviter_id?: string
          status?: Database["pendingbot"]["Enums"]["join_request_status"]
        }
        Relationships: [
          {
            foreignKeyName: "group_member_invitations_conv_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      group_pledges: {
        Row: {
          created_at: string
          pledge_pnc_micros: number
          status: string
          subject_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          pledge_pnc_micros: number
          status?: string
          subject_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          pledge_pnc_micros?: number
          status?: string
          subject_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_pledges_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_pledges_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_pledges_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      group_pools: {
        Row: {
          share_index: number
          subject_id: string
          total_remaining_pnc_micros: number
          updated_at: string
        }
        Insert: {
          share_index?: number
          subject_id: string
          total_remaining_pnc_micros?: number
          updated_at?: string
        }
        Update: {
          share_index?: number
          subject_id?: string
          total_remaining_pnc_micros?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_pools_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: true
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_pools_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: true
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      group_subject_members: {
        Row: {
          can_create_crew: boolean
          can_manage_runners: boolean
          can_manage_wallet: boolean
          created_at: string
          granted_at: string
          granted_by: string | null
          role: string
          subject_id: string
          user_id: string
        }
        Insert: {
          can_create_crew?: boolean
          can_manage_runners?: boolean
          can_manage_wallet?: boolean
          created_at?: string
          granted_at?: string
          granted_by?: string | null
          role: string
          subject_id: string
          user_id: string
        }
        Update: {
          can_create_crew?: boolean
          can_manage_runners?: boolean
          can_manage_wallet?: boolean
          created_at?: string
          granted_at?: string
          granted_by?: string | null
          role?: string
          subject_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_subject_members_granted_by_fkey"
            columns: ["granted_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_subject_members_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_subject_members_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      human_help_requests: {
        Row: {
          created_at: string
          decided_at: string | null
          id: string
          reason: string | null
          requested_user_id: string
          requester_member_id: string
          responsible_subject_id: string
          status: string
          temporary_group_id: string
        }
        Insert: {
          created_at?: string
          decided_at?: string | null
          id?: string
          reason?: string | null
          requested_user_id: string
          requester_member_id: string
          responsible_subject_id: string
          status?: string
          temporary_group_id: string
        }
        Update: {
          created_at?: string
          decided_at?: string | null
          id?: string
          reason?: string | null
          requested_user_id?: string
          requester_member_id?: string
          responsible_subject_id?: string
          status?: string
          temporary_group_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "human_help_requests_requester_member_id_fkey"
            columns: ["requester_member_id"]
            isOneToOne: false
            referencedRelation: "temporary_group_members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "human_help_requests_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "human_help_requests_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "human_help_requests_temporary_group_id_fkey"
            columns: ["temporary_group_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      invites: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          expires_at: string | null
          metadata: Json
          used_at: string | null
          used_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          expires_at?: string | null
          metadata?: Json
          used_at?: string | null
          used_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          expires_at?: string | null
          metadata?: Json
          used_at?: string | null
          used_by?: string | null
        }
        Relationships: []
      }
      machine: {
        Row: {
          created_at: string
          crew_index_digest: string | null
          device_id: string | null
          display_name: string
          fly_machine_id: string | null
          id: string
          kind: string
          last_seen_at: string | null
          remote_control_enabled: boolean
          resync_alarmed_at: string | null
          resync_attempts: number
          resync_last_at: string | null
          state_digest: string | null
          status: string | null
          subject_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          crew_index_digest?: string | null
          device_id?: string | null
          display_name: string
          fly_machine_id?: string | null
          id?: string
          kind: string
          last_seen_at?: string | null
          remote_control_enabled?: boolean
          resync_alarmed_at?: string | null
          resync_attempts?: number
          resync_last_at?: string | null
          state_digest?: string | null
          status?: string | null
          subject_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          crew_index_digest?: string | null
          device_id?: string | null
          display_name?: string
          fly_machine_id?: string | null
          id?: string
          kind?: string
          last_seen_at?: string | null
          remote_control_enabled?: boolean
          resync_alarmed_at?: string | null
          resync_attempts?: number
          resync_last_at?: string | null
          state_digest?: string | null
          status?: string | null
          subject_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "machine_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "machine_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      machine_crew_index: {
        Row: {
          attention: boolean
          crew_number: number | null
          exposure: string
          has_working_directory: boolean
          id: string
          local_crew_id: string
          local_updated_at: string | null
          machine_id: string
          member_count: number
          parent_local_crew_ids: string[]
          revoked_at: string | null
          session_count: number
          subject_id: string
          synced_at: string
          title: string
        }
        Insert: {
          attention?: boolean
          crew_number?: number | null
          exposure: string
          has_working_directory?: boolean
          id?: string
          local_crew_id: string
          local_updated_at?: string | null
          machine_id: string
          member_count?: number
          parent_local_crew_ids?: string[]
          revoked_at?: string | null
          session_count?: number
          subject_id: string
          synced_at?: string
          title: string
        }
        Update: {
          attention?: boolean
          crew_number?: number | null
          exposure?: string
          has_working_directory?: boolean
          id?: string
          local_crew_id?: string
          local_updated_at?: string | null
          machine_id?: string
          member_count?: number
          parent_local_crew_ids?: string[]
          revoked_at?: string | null
          session_count?: number
          subject_id?: string
          synced_at?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "machine_crew_index_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "machine"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "machine_crew_index_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "machine_crew_index_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      mcp_servers: {
        Row: {
          auth_header_name: string | null
          auth_kind: string
          created_at: string
          enabled: boolean
          id: string
          last_health_check_at: string | null
          last_health_error: string | null
          name: string
          notes: string | null
          secret_ref: string | null
          transport: string
          updated_at: string
          url: string
        }
        Insert: {
          auth_header_name?: string | null
          auth_kind?: string
          created_at?: string
          enabled?: boolean
          id?: string
          last_health_check_at?: string | null
          last_health_error?: string | null
          name: string
          notes?: string | null
          secret_ref?: string | null
          transport?: string
          updated_at?: string
          url: string
        }
        Update: {
          auth_header_name?: string | null
          auth_kind?: string
          created_at?: string
          enabled?: boolean
          id?: string
          last_health_check_at?: string | null
          last_health_error?: string | null
          name?: string
          notes?: string | null
          secret_ref?: string | null
          transport?: string
          updated_at?: string
          url?: string
        }
        Relationships: []
      }
      messages: {
        Row: {
          attachments: Json | null
          bubble_group_id: string | null
          citations: Json | null
          client_message_id: string
          content: string | null
          content_tsv: unknown
          conversation_id: string
          created_at: string
          id: string
          log_kind: string | null
          log_payload: Json | null
          message_seq: number | null
          metadata: Json | null
          model_provider: string | null
          model_slug: string | null
          parent_message_id: string | null
          replaced_by_message_id: string | null
          replaces_message_id: string | null
          role: string
          sender_bot_id: string | null
          status: string
          stop_requested: boolean
          updated_at: string
          user_id: string | null
        }
        Insert: {
          attachments?: Json | null
          bubble_group_id?: string | null
          citations?: Json | null
          client_message_id: string
          content?: string | null
          content_tsv?: unknown
          conversation_id: string
          created_at?: string
          id?: string
          log_kind?: string | null
          log_payload?: Json | null
          message_seq?: number | null
          metadata?: Json | null
          model_provider?: string | null
          model_slug?: string | null
          parent_message_id?: string | null
          replaced_by_message_id?: string | null
          replaces_message_id?: string | null
          role: string
          sender_bot_id?: string | null
          status?: string
          stop_requested?: boolean
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          attachments?: Json | null
          bubble_group_id?: string | null
          citations?: Json | null
          client_message_id?: string
          content?: string | null
          content_tsv?: unknown
          conversation_id?: string
          created_at?: string
          id?: string
          log_kind?: string | null
          log_payload?: Json | null
          message_seq?: number | null
          metadata?: Json | null
          model_provider?: string | null
          model_slug?: string | null
          parent_message_id?: string | null
          replaced_by_message_id?: string | null
          replaces_message_id?: string | null
          role?: string
          sender_bot_id?: string | null
          status?: string
          stop_requested?: boolean
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "messages_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_parent_message_id_fkey"
            columns: ["parent_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_replaced_by_message_id_fkey"
            columns: ["replaced_by_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_replaces_message_id_fkey"
            columns: ["replaces_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_sender_bot_id_fkey"
            columns: ["sender_bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
        ]
      }
      model_guesses: {
        Row: {
          actual_provider: string | null
          actual_slug: string
          conversation_id: string
          correct: boolean | null
          created_at: string
          guessed_slug: string | null
          id: string
          user_id: string
        }
        Insert: {
          actual_provider?: string | null
          actual_slug: string
          conversation_id: string
          correct?: boolean | null
          created_at?: string
          guessed_slug?: string | null
          id?: string
          user_id: string
        }
        Update: {
          actual_provider?: string | null
          actual_slug?: string
          conversation_id?: string
          correct?: boolean | null
          created_at?: string
          guessed_slug?: string | null
          id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "model_guesses_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      model_presets: {
        Row: {
          default_selected: boolean
          description: string
          enabled: boolean
          params: Json
          resolver_kind: string
          slug: string
          sort_order: number
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          default_selected?: boolean
          description?: string
          enabled?: boolean
          params?: Json
          resolver_kind: string
          slug: string
          sort_order?: number
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          default_selected?: boolean
          description?: string
          enabled?: boolean
          params?: Json
          resolver_kind?: string
          slug?: string
          sort_order?: number
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      permission_requests: {
        Row: {
          crew_session_id: string
          decided_at: string | null
          decided_by_user_id: string | null
          detail: Json
          id: string
          reply_text: string | null
          request_kind: string
          requested_action: string
          requested_at: string
          responsible_subject_id: string
          risk_level: string
          status: string
        }
        Insert: {
          crew_session_id: string
          decided_at?: string | null
          decided_by_user_id?: string | null
          detail?: Json
          id?: string
          reply_text?: string | null
          request_kind?: string
          requested_action: string
          requested_at?: string
          responsible_subject_id: string
          risk_level: string
          status?: string
        }
        Update: {
          crew_session_id?: string
          decided_at?: string | null
          decided_by_user_id?: string | null
          detail?: Json
          id?: string
          reply_text?: string | null
          request_kind?: string
          requested_action?: string
          requested_at?: string
          responsible_subject_id?: string
          risk_level?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "permission_requests_crew_session_id_fkey"
            columns: ["crew_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "permission_requests_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "permission_requests_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      place_names: {
        Row: {
          name: string
        }
        Insert: {
          name: string
        }
        Update: {
          name?: string
        }
        Relationships: []
      }
      pnc_ledger: {
        Row: {
          created_at: string
          delta_pnc_micros: number
          external_ref: string
          gross_paid_usd_cents: number | null
          id: string
          kind: string
          markup_snapshot: number | null
          net_revenue_usd_cents: number | null
          polar_synced: boolean
          raw: Json | null
          source: string
          subject_id: string
        }
        Insert: {
          created_at?: string
          delta_pnc_micros: number
          external_ref: string
          gross_paid_usd_cents?: number | null
          id?: string
          kind: string
          markup_snapshot?: number | null
          net_revenue_usd_cents?: number | null
          polar_synced?: boolean
          raw?: Json | null
          source: string
          subject_id: string
        }
        Update: {
          created_at?: string
          delta_pnc_micros?: number
          external_ref?: string
          gross_paid_usd_cents?: number | null
          id?: string
          kind?: string
          markup_snapshot?: number | null
          net_revenue_usd_cents?: number | null
          polar_synced?: boolean
          raw?: Json | null
          source?: string
          subject_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pnc_ledger_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pnc_ledger_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      preset_conversation_templates: {
        Row: {
          base_ts: string
          bot_slug: string
          enabled: boolean
          messages: Json
          slug: string
          sort_order: number
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          base_ts?: string
          bot_slug: string
          enabled?: boolean
          messages?: Json
          slug: string
          sort_order?: number
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          base_ts?: string
          bot_slug?: string
          enabled?: boolean
          messages?: Json
          slug?: string
          sort_order?: number
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      preset_group_templates: {
        Row: {
          bot_slugs: string[]
          enabled: boolean
          join_policy: Database["pendingbot"]["Enums"]["group_join_policy"]
          messages: Json
          slug: string
          sort_order: number
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          bot_slugs?: string[]
          enabled?: boolean
          join_policy?: Database["pendingbot"]["Enums"]["group_join_policy"]
          messages?: Json
          slug: string
          sort_order?: number
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          bot_slugs?: string[]
          enabled?: boolean
          join_policy?: Database["pendingbot"]["Enums"]["group_join_policy"]
          messages?: Json
          slug?: string
          sort_order?: number
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      preset_letters: {
        Row: {
          body_md: string
          slug: string
          summary: string
          title: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        Insert: {
          body_md: string
          slug: string
          summary: string
          title: string
          updated_at?: string
          updated_by?: string | null
          version?: number
        }
        Update: {
          body_md?: string
          slug?: string
          summary?: string
          title?: string
          updated_at?: string
          updated_by?: string | null
          version?: number
        }
        Relationships: []
      }
      realtime_sessions: {
        Row: {
          bot_id: string
          conversation_id: string
          created_at: string
          ended_at: string | null
          openai_session_id: string | null
          session_id: string
          user_id: string
        }
        Insert: {
          bot_id: string
          conversation_id: string
          created_at?: string
          ended_at?: string | null
          openai_session_id?: string | null
          session_id: string
          user_id: string
        }
        Update: {
          bot_id?: string
          conversation_id?: string
          created_at?: string
          ended_at?: string | null
          openai_session_id?: string | null
          session_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "realtime_sessions_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "realtime_sessions_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      redemption_codes: {
        Row: {
          batch_label: string | null
          code: string
          created_at: string
          created_by: string | null
          credits: number
          id: string
          notes: string | null
          redeemed_at: string | null
          redeemed_by: string | null
          status: string
        }
        Insert: {
          batch_label?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          credits: number
          id?: string
          notes?: string | null
          redeemed_at?: string | null
          redeemed_by?: string | null
          status?: string
        }
        Update: {
          batch_label?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          credits?: number
          id?: string
          notes?: string | null
          redeemed_at?: string | null
          redeemed_by?: string | null
          status?: string
        }
        Relationships: []
      }
      runner_hosts: {
        Row: {
          allowed_runner_kinds: Json
          capabilities: Json
          created_at: string
          device_id: string | null
          display_name: string
          id: string
          last_seen_at: string | null
          platform: string
          responsible_subject_id: string
          status: string
          updated_at: string
        }
        Insert: {
          allowed_runner_kinds?: Json
          capabilities?: Json
          created_at?: string
          device_id?: string | null
          display_name: string
          id?: string
          last_seen_at?: string | null
          platform: string
          responsible_subject_id: string
          status?: string
          updated_at?: string
        }
        Update: {
          allowed_runner_kinds?: Json
          capabilities?: Json
          created_at?: string
          device_id?: string | null
          display_name?: string
          id?: string
          last_seen_at?: string | null
          platform?: string
          responsible_subject_id?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "runner_hosts_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "device_tokens"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "runner_hosts_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "runner_hosts_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      runner_leases: {
        Row: {
          created_at: string
          crew_session_id: string
          expires_at: string
          granted_by_user_id: string | null
          id: string
          lease_status: string
          lease_token_hash: string
          released_at: string | null
          responsible_subject_id: string
          runner_host_id: string
        }
        Insert: {
          created_at?: string
          crew_session_id: string
          expires_at: string
          granted_by_user_id?: string | null
          id?: string
          lease_status?: string
          lease_token_hash: string
          released_at?: string | null
          responsible_subject_id: string
          runner_host_id: string
        }
        Update: {
          created_at?: string
          crew_session_id?: string
          expires_at?: string
          granted_by_user_id?: string | null
          id?: string
          lease_status?: string
          lease_token_hash?: string
          released_at?: string | null
          responsible_subject_id?: string
          runner_host_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "runner_leases_crew_session_id_fkey"
            columns: ["crew_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "runner_leases_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "runner_leases_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "runner_leases_runner_host_id_fkey"
            columns: ["runner_host_id"]
            isOneToOne: false
            referencedRelation: "runner_hosts"
            referencedColumns: ["id"]
          },
        ]
      }
      session_dependencies: {
        Row: {
          created_at: string
          crew_session_id: string
          dependency_type: string
          depends_on_session_id: string | null
          id: string
          note: string | null
          resolved_at: string | null
          status: string
        }
        Insert: {
          created_at?: string
          crew_session_id: string
          dependency_type: string
          depends_on_session_id?: string | null
          id?: string
          note?: string | null
          resolved_at?: string | null
          status?: string
        }
        Update: {
          created_at?: string
          crew_session_id?: string
          dependency_type?: string
          depends_on_session_id?: string | null
          id?: string
          note?: string | null
          resolved_at?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_dependencies_crew_session_id_fkey"
            columns: ["crew_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_dependencies_depends_on_session_id_fkey"
            columns: ["depends_on_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      session_events: {
        Row: {
          created_at: string
          crew_session_id: string
          event_type: string
          id: string
          payload: Json
          summary: string | null
          visibility: string
        }
        Insert: {
          created_at?: string
          crew_session_id: string
          event_type: string
          id?: string
          payload?: Json
          summary?: string | null
          visibility?: string
        }
        Update: {
          created_at?: string
          crew_session_id?: string
          event_type?: string
          id?: string
          payload?: Json
          summary?: string | null
          visibility?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_events_crew_session_id_fkey"
            columns: ["crew_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      session_file_claims: {
        Row: {
          claim_type: string
          created_at: string
          crew_session_id: string
          id: string
          path_pattern: string
          released_at: string | null
          status: string
          workspace_root: string
        }
        Insert: {
          claim_type: string
          created_at?: string
          crew_session_id: string
          id?: string
          path_pattern: string
          released_at?: string | null
          status?: string
          workspace_root: string
        }
        Update: {
          claim_type?: string
          created_at?: string
          crew_session_id?: string
          id?: string
          path_pattern?: string
          released_at?: string | null
          status?: string
          workspace_root?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_file_claims_crew_session_id_fkey"
            columns: ["crew_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      session_mailbox_items: {
        Row: {
          announcement_id: string | null
          created_at: string
          crew_conversation_id: string
          delivered_at: string | null
          id: string
          message_kind: string
          payload: Json
          read_at: string | null
          recipient_session_id: string | null
          responsible_subject_id: string
          sender_kind: string | null
          sender_member_id: string | null
          sender_session_id: string | null
          source_message_id: string | null
          status: string
          summary: string
        }
        Insert: {
          announcement_id?: string | null
          created_at?: string
          crew_conversation_id: string
          delivered_at?: string | null
          id?: string
          message_kind?: string
          payload?: Json
          read_at?: string | null
          recipient_session_id?: string | null
          responsible_subject_id: string
          sender_kind?: string | null
          sender_member_id?: string | null
          sender_session_id?: string | null
          source_message_id?: string | null
          status?: string
          summary: string
        }
        Update: {
          announcement_id?: string | null
          created_at?: string
          crew_conversation_id?: string
          delivered_at?: string | null
          id?: string
          message_kind?: string
          payload?: Json
          read_at?: string | null
          recipient_session_id?: string | null
          responsible_subject_id?: string
          sender_kind?: string | null
          sender_member_id?: string | null
          sender_session_id?: string | null
          source_message_id?: string | null
          status?: string
          summary?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_mailbox_items_announcement_id_fkey"
            columns: ["announcement_id"]
            isOneToOne: false
            referencedRelation: "crew_announcements"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_mailbox_items_crew_conversation_id_fkey"
            columns: ["crew_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_mailbox_items_recipient_session_id_fkey"
            columns: ["recipient_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_mailbox_items_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_mailbox_items_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_mailbox_items_sender_member_id_fkey"
            columns: ["sender_member_id"]
            isOneToOne: false
            referencedRelation: "temporary_group_members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_mailbox_items_sender_session_id_fkey"
            columns: ["sender_session_id"]
            isOneToOne: false
            referencedRelation: "crew_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_mailbox_items_source_message_id_fkey"
            columns: ["source_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
        ]
      }
      short_links: {
        Row: {
          click_count: number
          created_at: string
          enabled: boolean
          expires_at: string | null
          last_clicked_at: string | null
          note: string | null
          slug: string
          target_url: string
          updated_at: string
        }
        Insert: {
          click_count?: number
          created_at?: string
          enabled?: boolean
          expires_at?: string | null
          last_clicked_at?: string | null
          note?: string | null
          slug: string
          target_url: string
          updated_at?: string
        }
        Update: {
          click_count?: number
          created_at?: string
          enabled?: boolean
          expires_at?: string | null
          last_clicked_at?: string | null
          note?: string | null
          slug?: string
          target_url?: string
          updated_at?: string
        }
        Relationships: []
      }
      skill_subscriptions: {
        Row: {
          conversation_id: string | null
          installed_at: string
          skill_id: string
          user_id: string
        }
        Insert: {
          conversation_id?: string | null
          installed_at?: string
          skill_id: string
          user_id: string
        }
        Update: {
          conversation_id?: string | null
          installed_at?: string
          skill_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "skill_subscriptions_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "skill_subscriptions_skill_id_fkey"
            columns: ["skill_id"]
            isOneToOne: false
            referencedRelation: "skills"
            referencedColumns: ["id"]
          },
        ]
      }
      skill_versions: {
        Row: {
          body_md: string
          created_at: string
          edited_by: string | null
          frontmatter: Json
          id: string
          skill_id: string
        }
        Insert: {
          body_md: string
          created_at?: string
          edited_by?: string | null
          frontmatter: Json
          id?: string
          skill_id: string
        }
        Update: {
          body_md?: string
          created_at?: string
          edited_by?: string | null
          frontmatter?: Json
          id?: string
          skill_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "skill_versions_skill_id_fkey"
            columns: ["skill_id"]
            isOneToOne: false
            referencedRelation: "skills"
            referencedColumns: ["id"]
          },
        ]
      }
      skills: {
        Row: {
          body_md: string
          bot_id: string | null
          conversation_id: string | null
          created_at: string
          forked_from: string | null
          frontmatter: Json
          id: string
          owner_id: string | null
          provider: string
          updated_at: string
          user_id: string | null
          visibility: string
        }
        Insert: {
          body_md: string
          bot_id?: string | null
          conversation_id?: string | null
          created_at?: string
          forked_from?: string | null
          frontmatter: Json
          id?: string
          owner_id?: string | null
          provider?: string
          updated_at?: string
          user_id?: string | null
          visibility?: string
        }
        Update: {
          body_md?: string
          bot_id?: string | null
          conversation_id?: string | null
          created_at?: string
          forked_from?: string | null
          frontmatter?: Json
          id?: string
          owner_id?: string | null
          provider?: string
          updated_at?: string
          user_id?: string | null
          visibility?: string
        }
        Relationships: [
          {
            foreignKeyName: "skills_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "skills_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "skills_forked_from_fkey"
            columns: ["forked_from"]
            isOneToOne: false
            referencedRelation: "skills"
            referencedColumns: ["id"]
          },
        ]
      }
      subject_device_grants: {
        Row: {
          app_kind: string
          created_at: string
          device_name: string
          device_public_key: string
          expires_at: string | null
          grant_kind: string
          granted_by_user_id: string | null
          id: string
          last_used_at: string | null
          parent_family_credential_id: string | null
          platform: string
          revoked_at: string | null
          scopes: Json
          status: string
          subject_id: string
          token_hash: string
        }
        Insert: {
          app_kind: string
          created_at?: string
          device_name: string
          device_public_key: string
          expires_at?: string | null
          grant_kind: string
          granted_by_user_id?: string | null
          id?: string
          last_used_at?: string | null
          parent_family_credential_id?: string | null
          platform?: string
          revoked_at?: string | null
          scopes?: Json
          status?: string
          subject_id: string
          token_hash: string
        }
        Update: {
          app_kind?: string
          created_at?: string
          device_name?: string
          device_public_key?: string
          expires_at?: string | null
          grant_kind?: string
          granted_by_user_id?: string | null
          id?: string
          last_used_at?: string | null
          parent_family_credential_id?: string | null
          platform?: string
          revoked_at?: string | null
          scopes?: Json
          status?: string
          subject_id?: string
          token_hash?: string
        }
        Relationships: [
          {
            foreignKeyName: "subject_device_grants_parent_family_credential_id_fkey"
            columns: ["parent_family_credential_id"]
            isOneToOne: false
            referencedRelation: "family_sso_credentials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_device_grants_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_device_grants_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      subject_device_login_challenges: {
        Row: {
          app_kind: string
          approved_at: string | null
          approved_by_user_id: string | null
          approved_subject_id: string | null
          challenge_secret_hash: string
          code: string
          consumed_at: string | null
          created_at: string
          device_name: string
          device_public_key: string
          expires_at: string
          grant_kind: string | null
          id: string
          issued_grant_id: string | null
          platform: string
          requested_scopes: Json
          requested_subject_id: string | null
          status: string
        }
        Insert: {
          app_kind: string
          approved_at?: string | null
          approved_by_user_id?: string | null
          approved_subject_id?: string | null
          challenge_secret_hash: string
          code: string
          consumed_at?: string | null
          created_at?: string
          device_name: string
          device_public_key: string
          expires_at?: string
          grant_kind?: string | null
          id?: string
          issued_grant_id?: string | null
          platform?: string
          requested_scopes?: Json
          requested_subject_id?: string | null
          status?: string
        }
        Update: {
          app_kind?: string
          approved_at?: string | null
          approved_by_user_id?: string | null
          approved_subject_id?: string | null
          challenge_secret_hash?: string
          code?: string
          consumed_at?: string | null
          created_at?: string
          device_name?: string
          device_public_key?: string
          expires_at?: string
          grant_kind?: string | null
          id?: string
          issued_grant_id?: string | null
          platform?: string
          requested_scopes?: Json
          requested_subject_id?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "subject_device_login_challenges_approved_subject_id_fkey"
            columns: ["approved_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_device_login_challenges_approved_subject_id_fkey"
            columns: ["approved_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_device_login_challenges_issued_grant_fkey"
            columns: ["issued_grant_id"]
            isOneToOne: false
            referencedRelation: "subject_device_grants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_device_login_challenges_requested_subject_id_fkey"
            columns: ["requested_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_device_login_challenges_requested_subject_id_fkey"
            columns: ["requested_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      subjects: {
        Row: {
          created_at: string
          created_by: string | null
          display_name: string
          group_conversation_id: string | null
          id: string
          kind: string
          status: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          display_name: string
          group_conversation_id?: string | null
          id?: string
          kind: string
          status?: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          display_name?: string
          group_conversation_id?: string | null
          id?: string
          kind?: string
          status?: string
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "subjects_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subjects_group_conversation_id_fkey"
            columns: ["group_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      temporary_group_members: {
        Row: {
          bot_id: string | null
          capabilities: Json
          code_session_id: string | null
          conversation_id: string
          created_at: string
          display_name: string
          ephemeral_spec: Json
          id: string
          invited_by_member_id: string | null
          member_kind: string
          represents_crew_id: string | null
          role: string
          status: string
          user_id: string | null
        }
        Insert: {
          bot_id?: string | null
          capabilities?: Json
          code_session_id?: string | null
          conversation_id: string
          created_at?: string
          display_name: string
          ephemeral_spec?: Json
          id?: string
          invited_by_member_id?: string | null
          member_kind: string
          represents_crew_id?: string | null
          role?: string
          status?: string
          user_id?: string | null
        }
        Update: {
          bot_id?: string | null
          capabilities?: Json
          code_session_id?: string | null
          conversation_id?: string
          created_at?: string
          display_name?: string
          ephemeral_spec?: Json
          id?: string
          invited_by_member_id?: string | null
          member_kind?: string
          represents_crew_id?: string | null
          role?: string
          status?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "temporary_group_members_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_members_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_members_invited_by_member_id_fkey"
            columns: ["invited_by_member_id"]
            isOneToOne: false
            referencedRelation: "temporary_group_members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_members_represents_crew_id_fkey"
            columns: ["represents_crew_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      temporary_group_meta: {
        Row: {
          captain_bot_id: string | null
          closed_at: string | null
          conversation_id: string
          created_at: string
          initiator_bot_id: string | null
          initiator_type: string
          initiator_user_id: string | null
          local_master_enabled: boolean
          machine_id: string | null
          master_bot_id: string | null
          master_member_id: string | null
          parent_temporary_group_id: string | null
          permission_mode: string
          responsibility_mode: string
          responsible_subject_id: string | null
          root_temporary_group_id: string | null
          runtime_location: string
          source_conversation_id: string | null
          status: string
          temporary_kind: string
          title: string | null
          updated_at: string
          working_directory: string | null
        }
        Insert: {
          captain_bot_id?: string | null
          closed_at?: string | null
          conversation_id: string
          created_at?: string
          initiator_bot_id?: string | null
          initiator_type: string
          initiator_user_id?: string | null
          local_master_enabled?: boolean
          machine_id?: string | null
          master_bot_id?: string | null
          master_member_id?: string | null
          parent_temporary_group_id?: string | null
          permission_mode?: string
          responsibility_mode?: string
          responsible_subject_id?: string | null
          root_temporary_group_id?: string | null
          runtime_location?: string
          source_conversation_id?: string | null
          status?: string
          temporary_kind: string
          title?: string | null
          updated_at?: string
          working_directory?: string | null
        }
        Update: {
          captain_bot_id?: string | null
          closed_at?: string | null
          conversation_id?: string
          created_at?: string
          initiator_bot_id?: string | null
          initiator_type?: string
          initiator_user_id?: string | null
          local_master_enabled?: boolean
          machine_id?: string | null
          master_bot_id?: string | null
          master_member_id?: string | null
          parent_temporary_group_id?: string | null
          permission_mode?: string
          responsibility_mode?: string
          responsible_subject_id?: string | null
          root_temporary_group_id?: string | null
          runtime_location?: string
          source_conversation_id?: string | null
          status?: string
          temporary_kind?: string
          title?: string | null
          updated_at?: string
          working_directory?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "temporary_group_meta_captain_bot_id_fkey"
            columns: ["captain_bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: true
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_initiator_bot_id_fkey"
            columns: ["initiator_bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "machine"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_master_bot_id_fkey"
            columns: ["master_bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_master_member_id_fkey"
            columns: ["master_member_id"]
            isOneToOne: false
            referencedRelation: "temporary_group_members"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_parent_temporary_group_id_fkey"
            columns: ["parent_temporary_group_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_responsible_subject_id_fkey"
            columns: ["responsible_subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_root_temporary_group_id_fkey"
            columns: ["root_temporary_group_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "temporary_group_meta_source_conversation_id_fkey"
            columns: ["source_conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      tools: {
        Row: {
          created_at: string
          description: string | null
          enabled: boolean
          id: string
          key: string
          kind: string
          mcp_server_id: string | null
          model_description: string | null
          notes: string | null
          scopes: Json
          updated_at: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          enabled?: boolean
          id?: string
          key: string
          kind: string
          mcp_server_id?: string | null
          model_description?: string | null
          notes?: string | null
          scopes?: Json
          updated_at?: string
        }
        Update: {
          created_at?: string
          description?: string | null
          enabled?: boolean
          id?: string
          key?: string
          kind?: string
          mcp_server_id?: string | null
          model_description?: string | null
          notes?: string | null
          scopes?: Json
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "tools_mcp_fkey"
            columns: ["mcp_server_id"]
            isOneToOne: false
            referencedRelation: "mcp_servers"
            referencedColumns: ["id"]
          },
        ]
      }
      user_bot_contacts: {
        Row: {
          added_at: string
          added_via: string
          alias: string | null
          bot_id: string
          invited_by: string | null
          user_id: string
        }
        Insert: {
          added_at?: string
          added_via?: string
          alias?: string | null
          bot_id: string
          invited_by?: string | null
          user_id: string
        }
        Update: {
          added_at?: string
          added_via?: string
          alias?: string | null
          bot_id?: string
          invited_by?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_bot_contacts_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
        ]
      }
      user_contacts: {
        Row: {
          added_via_handle_id: string | null
          alias: string | null
          contact_user_id: string
          created_at: string
          user_id: string
        }
        Insert: {
          added_via_handle_id?: string | null
          alias?: string | null
          contact_user_id: string
          created_at?: string
          user_id: string
        }
        Update: {
          added_via_handle_id?: string | null
          alias?: string | null
          contact_user_id?: string
          created_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_contacts_added_via_handle_id_fkey"
            columns: ["added_via_handle_id"]
            isOneToOne: false
            referencedRelation: "user_handles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_handles: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          kind: string
          label: string | null
          revoked_at: string | null
          user_id: string
          value: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          kind?: string
          label?: string | null
          revoked_at?: string | null
          user_id: string
          value: string
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          kind?: string
          label?: string | null
          revoked_at?: string | null
          user_id?: string
          value?: string
        }
        Relationships: []
      }
      user_quota: {
        Row: {
          daily_limit_usd: number
          daily_used_usd: number
          monthly_limit_usd: number
          monthly_used_usd: number
          reset_daily_at: string | null
          reset_monthly_at: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          daily_limit_usd?: number
          daily_used_usd?: number
          monthly_limit_usd?: number
          monthly_used_usd?: number
          reset_daily_at?: string | null
          reset_monthly_at?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          daily_limit_usd?: number
          daily_used_usd?: number
          monthly_limit_usd?: number
          monthly_used_usd?: number
          reset_daily_at?: string | null
          reset_monthly_at?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      user_settings: {
        Row: {
          custom_settings: Json
          locale: string | null
          notifications_enabled: boolean
          theme: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          custom_settings?: Json
          locale?: string | null
          notifications_enabled?: boolean
          theme?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          custom_settings?: Json
          locale?: string | null
          notifications_enabled?: boolean
          theme?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      user_unread_counts: {
        Row: {
          conversation_id: string
          last_message_at: string | null
          last_message_id: string | null
          last_message_preview: string | null
          last_message_seq: number | null
          unread_count: number
          user_id: string
        }
        Insert: {
          conversation_id: string
          last_message_at?: string | null
          last_message_id?: string | null
          last_message_preview?: string | null
          last_message_seq?: number | null
          unread_count?: number
          user_id: string
        }
        Update: {
          conversation_id?: string
          last_message_at?: string | null
          last_message_id?: string | null
          last_message_preview?: string | null
          last_message_seq?: number | null
          unread_count?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_unread_counts_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      users: {
        Row: {
          avatar_path: string | null
          bio: string | null
          created_at: string
          custom_fields: Json
          display_name: string
          email: string | null
          id: string
          pending_deletion_at: string | null
          pending_deletion_sentiment: string | null
          updated_at: string
        }
        Insert: {
          avatar_path?: string | null
          bio?: string | null
          created_at?: string
          custom_fields?: Json
          display_name?: string
          email?: string | null
          id: string
          pending_deletion_at?: string | null
          pending_deletion_sentiment?: string | null
          updated_at?: string
        }
        Update: {
          avatar_path?: string | null
          bio?: string | null
          created_at?: string
          custom_fields?: Json
          display_name?: string
          email?: string | null
          id?: string
          pending_deletion_at?: string | null
          pending_deletion_sentiment?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      voice_active_calls: {
        Row: {
          conversation_id: string
          initiator_id: string
          started_at: string
        }
        Insert: {
          conversation_id: string
          initiator_id: string
          started_at?: string
        }
        Update: {
          conversation_id?: string
          initiator_id?: string
          started_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "voice_active_calls_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: true
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      web_tool_prices: {
        Row: {
          kind: string
          notes: string | null
          provider: string
          unit_cost_usd: number
          updated_at: string
        }
        Insert: {
          kind: string
          notes?: string | null
          provider: string
          unit_cost_usd: number
          updated_at?: string
        }
        Update: {
          kind?: string
          notes?: string | null
          provider?: string
          unit_cost_usd?: number
          updated_at?: string
        }
        Relationships: []
      }
      welcome_bonus_grants: {
        Row: {
          granted_at: string
          normalized_email: string
          subject_id: string
        }
        Insert: {
          granted_at?: string
          normalized_email: string
          subject_id: string
        }
        Update: {
          granted_at?: string
          normalized_email?: string
          subject_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "welcome_bonus_grants_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "welcome_bonus_grants_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      bi_bot_creations: {
        Row: {
          created_at: string | null
          creator_id: string | null
        }
        Insert: {
          created_at?: string | null
          creator_id?: string | null
        }
        Update: {
          created_at?: string | null
          creator_id?: string | null
        }
        Relationships: []
      }
      bi_cost_by_category: {
        Row: {
          cost_credits: number | null
          cost_usd: number | null
          created_at: string | null
          input_tokens: number | null
          model_id: string | null
          output_tokens: number | null
          task_type: string | null
          tool_cost_usd: number | null
          total_tokens: number | null
        }
        Insert: {
          cost_credits?: number | null
          cost_usd?: number | null
          created_at?: string | null
          input_tokens?: number | null
          model_id?: string | null
          output_tokens?: number | null
          task_type?: string | null
          tool_cost_usd?: number | null
          total_tokens?: number | null
        }
        Update: {
          cost_credits?: number | null
          cost_usd?: number | null
          created_at?: string | null
          input_tokens?: number | null
          model_id?: string | null
          output_tokens?: number | null
          task_type?: string | null
          tool_cost_usd?: number | null
          total_tokens?: number | null
        }
        Relationships: []
      }
      bi_group_joins_approved: {
        Row: {
          created_at: string | null
          decided_at: string | null
          requester_id: string | null
        }
        Insert: {
          created_at?: string | null
          decided_at?: string | null
          requester_id?: string | null
        }
        Update: {
          created_at?: string | null
          decided_at?: string | null
          requester_id?: string | null
        }
        Relationships: []
      }
      bi_group_pool_detail: {
        Row: {
          active_contributors: number | null
          active_pledgers: number | null
          contributed_micros: number | null
          group_name: string | null
          pledged_micros: number | null
          pool_remaining_micros: number | null
          share_index: number | null
          subject_id: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "group_pools_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: true
            referencedRelation: "bi_subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_pools_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: true
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      bi_group_pool_summary: {
        Row: {
          active_contributed_micros: number | null
          active_contributor_groups: number | null
          active_pledge_groups: number | null
          active_pledged_micros: number | null
          pool_remaining_micros: number | null
        }
        Relationships: []
      }
      bi_subjects: {
        Row: {
          display_name: string | null
          id: string | null
          kind: string | null
          subject_type: string | null
          user_id: string | null
        }
        Insert: {
          display_name?: string | null
          id?: string | null
          kind?: string | null
          subject_type?: string | null
          user_id?: string | null
        }
        Update: {
          display_name?: string | null
          id?: string | null
          kind?: string | null
          subject_type?: string | null
          user_id?: string | null
        }
        Relationships: []
      }
      crew_link_summaries: {
        Row: {
          captain_bot_id: string | null
          captain_member_id: string | null
          created_at: string | null
          current_crew_id: string | null
          direction: string | null
          linked_crew_id: string | null
          runtime_location: string | null
          status: string | null
          title: string | null
        }
        Relationships: []
      }
      crew_resolved_responsibility_shares: {
        Row: {
          crew_conversation_id: string | null
          share_bps: number | null
          source: string | null
          subject_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "temporary_group_meta_conversation_id_fkey"
            columns: ["crew_conversation_id"]
            isOneToOne: true
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      v_audit_daily: {
        Row: {
          avg_latency_ms: number | null
          cache_read_tokens: number | null
          cache_write_tokens: number | null
          cost_usd: number | null
          day: string | null
          error_count: number | null
          fallback_count: number | null
          input_tokens: number | null
          model_id: string | null
          output_tokens: number | null
          request_count: number | null
          task_type: string | null
          tool_cost_usd: number | null
          user_id: string | null
        }
        Relationships: []
      }
      v_audit_monthly: {
        Row: {
          avg_latency_ms: number | null
          cache_read_tokens: number | null
          cache_write_tokens: number | null
          cost_usd: number | null
          error_count: number | null
          input_tokens: number | null
          model_id: string | null
          month: string | null
          output_tokens: number | null
          request_count: number | null
          task_type: string | null
          tool_cost_usd: number | null
          user_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      _assert_group_role: {
        Args: { p_allowed_roles: string[]; p_conv_id: string }
        Returns: undefined
      }
      _crew_bot_display_name: { Args: { p_bot_id: string }; Returns: string }
      _crew_caller_can_act_for_subject: {
        Args: { p_caller: string; p_subject_id: string }
        Returns: boolean
      }
      _crew_caller_owns_bot: {
        Args: { p_bot_id: string; p_caller: string }
        Returns: boolean
      }
      _delete_account_internal: { Args: { p_uid: string }; Returns: undefined }
      _group_member_count: { Args: { p_conv_id: string }; Returns: number }
      _grp_caller_role: {
        Args: { p_caller: string; p_subject_id: string }
        Returns: string
      }
      _grp_require_caller: { Args: never; Returns: string }
      _grp_require_group_subject: {
        Args: { p_subject_id: string }
        Returns: undefined
      }
      _mint_random_group_handle: {
        Args: { p_conv_id: string; p_handle_type: string }
        Returns: undefined
      }
      _resolve_preset_bot_for_user: {
        Args: { p_slug: string; p_uid: string }
        Returns: string
      }
      _seed_preset_group_dialogue: {
        Args: { p_conv_id: string; p_messages: Json; p_user_id: string }
        Returns: undefined
      }
      accept_friend_request: {
        Args: { p_request_id: string; p_user_id: string }
        Returns: undefined
      }
      answer_interaction_request: {
        Args: { p_caller_user_id: string; p_id: string; p_reply_text: string }
        Returns: undefined
      }
      append_crew_session_event_from_runner: {
        Args: {
          p_crew_session_id: string
          p_event_type: string
          p_payload?: Json
          p_progress_summary?: string
          p_runner_host_id: string
          p_summary?: string
          p_visibility?: string
        }
        Returns: string
      }
      append_crew_session_event_from_runner_for_subject: {
        Args: {
          p_crew_session_id: string
          p_event_type: string
          p_payload?: Json
          p_progress_summary?: string
          p_responsible_subject_id: string
          p_runner_host_id: string
          p_summary?: string
          p_visibility?: string
        }
        Returns: string
      }
      apply_group_contribution: {
        Args: { p_amount_micros: number; p_subject_id: string }
        Returns: number
      }
      apply_group_pool_spend: {
        Args: { p_spend_micros: number; p_subject_id: string }
        Returns: undefined
      }
      apply_group_refund: {
        Args: { p_refund_micros: number; p_subject_id: string }
        Returns: undefined
      }
      apply_partial_withdraw: {
        Args: {
          p_amount_micros: number
          p_subject_id: string
          p_user_id: string
        }
        Returns: number
      }
      are_mutual_friends: { Args: { a: string; b: string }; Returns: boolean }
      billing_config_int: { Args: { p_key: string }; Returns: number }
      billing_redeem: { Args: { p_code: string }; Returns: Json }
      bootstrap_user_id: {
        Args: { p_email: string; p_meta: Json; p_uid: string }
        Returns: undefined
      }
      bot_invite_caller_can_invite: {
        Args: { p_bot_id: string; p_user_id: string }
        Returns: boolean
      }
      bot_invite_link_create: {
        Args: { p_bot_id: string }
        Returns: {
          expires_at: string
          token: string
        }[]
      }
      bot_invite_link_redeem: { Args: { p_token: string }; Returns: string }
      bot_invite_link_resolve: {
        Args: { p_token: string }
        Returns: {
          bot_id: string
          display_name: string
          inviter_name: string
          model_id: string
          slug: string
          visibility: string
        }[]
      }
      bot_invite_link_revoke: { Args: { p_token: string }; Returns: undefined }
      bot_invite_links_list: {
        Args: { p_bot_id: string }
        Returns: {
          created_at: string
          expires_at: string
          revoked_at: string
          token: string
        }[]
      }
      bot_invites_add: {
        Args: { p_bot_id: string; p_handle: string }
        Returns: string
      }
      bump_lookback_counter: {
        Args: { p_bot: string; p_interval: number; p_user: string }
        Returns: boolean
      }
      can_control_crew_session: {
        Args: { p_crew_session_id: string; p_user_id: string }
        Returns: boolean
      }
      can_view_crew_session: {
        Args: { p_crew_session_id: string; p_user_id: string }
        Returns: boolean
      }
      can_view_runner_host: {
        Args: { p_runner_host_id: string; p_user_id: string }
        Returns: boolean
      }
      can_view_runner_lease: {
        Args: { p_runner_lease_id: string; p_user_id: string }
        Returns: boolean
      }
      can_view_temporary_group: {
        Args: { p_conversation_id: string; p_user_id: string }
        Returns: boolean
      }
      cancel_account_deletion: { Args: never; Returns: boolean }
      claim_crew_session_for_subject: {
        Args: {
          p_crew_session_id: string
          p_responsible_subject_id: string
          p_runner_host_id: string
          p_runner_kinds?: Json
        }
        Returns: Json
      }
      claim_next_crew_session: {
        Args: { p_runner_host_id: string; p_runner_kinds?: Json }
        Returns: Json
      }
      claim_next_crew_session_for_subject: {
        Args: {
          p_responsible_subject_id: string
          p_runner_host_id: string
          p_runner_kinds?: Json
        }
        Returns: Json
      }
      consume_subject_device_login_challenge: {
        Args: {
          p_challenge_id: string
          p_challenge_secret_hash: string
          p_grant_id: string
          p_token_hash: string
        }
        Returns: Json
      }
      create_child_crew_inheriting_responsibility: {
        Args: { p_parent_crew_conversation_id: string; p_title?: string }
        Returns: string
      }
      create_child_crew_inheriting_responsibility_for_actor: {
        Args: {
          p_actor_user_id: string
          p_created_by_bot_id?: string
          p_created_by_kind?: string
          p_parent_crew_conversation_id: string
          p_title?: string
        }
        Returns: string
      }
      create_child_crew_inheriting_responsibility_for_subject: {
        Args: {
          p_actor_user_id: string
          p_granted_subject_id: string
          p_parent_crew_conversation_id: string
          p_title?: string
        }
        Returns: string
      }
      create_crew_announcement: {
        Args: {
          p_board_visible?: boolean
          p_crew_conversation_id: string
          p_message_kind?: string
          p_payload?: Json
          p_recipient_member_ids?: Json
          p_recipient_session_ids?: Json
          p_summary?: string
        }
        Returns: string
      }
      create_crew_announcement_for_subject: {
        Args: {
          p_actor_user_id: string
          p_board_visible?: boolean
          p_crew_conversation_id: string
          p_message_kind?: string
          p_payload?: Json
          p_recipient_member_ids?: Json
          p_recipient_session_ids?: Json
          p_responsible_subject_id: string
          p_summary?: string
        }
        Returns: string
      }
      create_crew_announcement_from_runner_for_subject: {
        Args: {
          p_board_visible?: boolean
          p_crew_session_id: string
          p_message_kind?: string
          p_payload?: Json
          p_recipient_member_ids?: Json
          p_recipient_session_ids?: Json
          p_responsible_subject_id: string
          p_runner_host_id: string
          p_summary?: string
        }
        Returns: string
      }
      create_crew_with_captain: {
        Args: {
          p_actor_user_id?: string
          p_captain_bot_id?: string
          p_captain_source?: string
          p_captain_template_name?: string
          p_machine_id?: string
          p_responsible_subject_id: string
          p_title: string
          p_working_directory?: string
        }
        Returns: string
      }
      create_interaction_request: {
        Args: { p_payload?: Json; p_question: string; p_session_id: string }
        Returns: string
      }
      create_permission_request: {
        Args: {
          p_action: string
          p_payload?: Json
          p_risk_level?: string
          p_session_id: string
        }
        Returns: string
      }
      crew_add_member_for_subject: {
        Args: {
          p_actor_user_id: string
          p_bot_id?: string
          p_crew_conversation_id: string
          p_member_kind: string
          p_user_id?: string
        }
        Returns: Json
      }
      crew_approve_share_change: {
        Args: { p_change_id: string; p_subject_id: string }
        Returns: string
      }
      crew_attach_as_child: {
        Args: {
          p_actor_user_id?: string
          p_child: string
          p_child_keeps_bps: number
          p_parent: string
        }
        Returns: undefined
      }
      crew_propose_share_change: {
        Args: {
          p_actor_user_id?: string
          p_crew_id: string
          p_proposal_payload: Json
          p_requires_subject_approvals: string[]
        }
        Returns: string
      }
      crew_propose_split_distinct: {
        Args: { p_seed?: number; p_shares: Json }
        Returns: Json
      }
      crew_recompute_shares: { Args: { p_crew_id: string }; Returns: undefined }
      crew_recompute_tiebreaker: {
        Args: { p_crew_id: string }
        Returns: undefined
      }
      decide_human_help_request: {
        Args: { p_decision: string; p_request_id: string }
        Returns: boolean
      }
      decide_permission_request: {
        Args: { p_caller_user_id: string; p_decision: string; p_id: string }
        Returns: undefined
      }
      enqueue_session_mailbox: {
        Args: {
          p_announcement_id?: string
          p_message_kind: string
          p_payload?: Json
          p_session_id: string
          p_source_message_id?: string
          p_summary: string
        }
        Returns: string
      }
      ensure_group_subject_for_conversation: {
        Args: { p_conversation_id: string }
        Returns: string
      }
      ensure_preset_handle: { Args: { p_uid: string }; Returns: undefined }
      ensure_self_conv: { Args: { p_uid: string }; Returns: string }
      ensure_user_subject: { Args: { p_user_id: string }; Returns: string }
      finalize_account_deletion: {
        Args: { p_force?: boolean; p_uid: string }
        Returns: undefined
      }
      finish_crew_session_from_runner: {
        Args: {
          p_crew_session_id: string
          p_payload?: Json
          p_progress_summary?: string
          p_runner_host_id: string
          p_status: string
          p_summary?: string
        }
        Returns: boolean
      }
      finish_crew_session_from_runner_for_subject: {
        Args: {
          p_crew_session_id: string
          p_payload?: Json
          p_progress_summary?: string
          p_responsible_subject_id: string
          p_runner_host_id: string
          p_status: string
          p_summary?: string
        }
        Returns: boolean
      }
      gen_preset_handle_value: { Args: never; Returns: string }
      get_bot_friends: {
        Args: { p_bot_id: string }
        Returns: {
          added_at: string
          avatar_path: string
          display_name: string
          invited_by: string
          user_id: string
        }[]
      }
      get_crew_whiteboard: {
        Args: { p_crew_id: string; p_since?: string }
        Returns: Json
      }
      group_continue_decide: {
        Args: {
          p_decision: string
          p_decision_message_id: string
          p_request_id: string
        }
        Returns: {
          conversation_id: string
          decided_at: string | null
          decided_by: string | null
          decision_message_id: string | null
          id: string
          pending_bot_ids: string[]
          prompt_message_id: string | null
          requested_at: string
          status: Database["pendingbot"]["Enums"]["continue_request_status"]
        }
        SetofOptions: {
          from: "*"
          to: "group_continue_requests"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      group_invite_bot: {
        Args: { p_bot_id: string; p_conv_id: string }
        Returns: undefined
      }
      group_invite_link_create: {
        Args: { p_conversation_id: string }
        Returns: {
          expires_at: string
          token: string
        }[]
      }
      group_invite_link_redeem: {
        Args: { p_message: string; p_token: string }
        Returns: {
          conversation_id: string
          joined: boolean
          request_id: string
        }[]
      }
      group_invite_link_resolve: {
        Args: { p_token: string }
        Returns: {
          conversation_id: string
          inviter_name: string
          join_policy: string
          member_count: number
          title: string
        }[]
      }
      group_invite_link_revoke: {
        Args: { p_token: string }
        Returns: undefined
      }
      group_invite_links_list: {
        Args: { p_conversation_id: string }
        Returns: {
          created_at: string
          expires_at: string
          revoked_at: string
          token: string
        }[]
      }
      group_invite_user: {
        Args: { p_conv_id: string; p_target_user_id: string }
        Returns: undefined
      }
      group_join_request_create: {
        Args: { p_handle_value: string; p_message: string }
        Returns: {
          conversation_id: string
          joined: boolean
          request_id: string
        }[]
      }
      group_join_request_decide: {
        Args: { p_approve: boolean; p_request_id: string }
        Returns: undefined
      }
      group_remove_bot: {
        Args: { p_bot_id: string; p_conv_id: string }
        Returns: undefined
      }
      group_remove_member: {
        Args: { p_conv_id: string; p_target_user_id: string }
        Returns: undefined
      }
      group_set_bot_description: {
        Args: { p_bot_id: string; p_conv_id: string; p_description: string }
        Returns: undefined
      }
      group_set_bot_nickname: {
        Args: { p_bot_id: string; p_conv_id: string; p_nickname: string }
        Returns: undefined
      }
      group_set_handle: {
        Args: { p_conv_id: string; p_handle_type: string; p_value: string }
        Returns: undefined
      }
      group_set_join_policy: {
        Args: { p_conv_id: string; p_policy: string }
        Returns: undefined
      }
      group_set_member_mute: {
        Args: { p_conv_id: string; p_muted: boolean }
        Returns: undefined
      }
      group_set_member_nickname: {
        Args: { p_conv_id: string; p_nickname: string }
        Returns: undefined
      }
      group_set_member_role: {
        Args: { p_conv_id: string; p_role: string; p_target_user_id: string }
        Returns: undefined
      }
      grp_add_member: {
        Args: { p_group_subject_id: string; p_user_id: string }
        Returns: undefined
      }
      grp_create_group_subject: {
        Args: { p_display_name: string }
        Returns: string
      }
      grp_demote_admin: {
        Args: { p_group_subject_id: string; p_user_id: string }
        Returns: undefined
      }
      grp_promote_to_admin: {
        Args: { p_group_subject_id: string; p_user_id: string }
        Returns: undefined
      }
      grp_remove_member: {
        Args: { p_group_subject_id: string; p_user_id: string }
        Returns: undefined
      }
      grp_transfer_ownership: {
        Args: { p_group_subject_id: string; p_to_user_id: string }
        Returns: undefined
      }
      is_bot_invitee: {
        Args: { p_bot_id: string; p_user_id: string }
        Returns: boolean
      }
      is_participant: { Args: { conv_id: string }; Returns: boolean }
      is_temporary_group_human_member: {
        Args: { p_conversation_id: string; p_user_id: string }
        Returns: boolean
      }
      issue_family_sso_credential: {
        Args: {
          p_device_name: string
          p_id: string
          p_token_hash: string
          p_user_id: string
        }
        Returns: string
      }
      list_bot_invitees: {
        Args: { p_bot_id: string }
        Returns: {
          display_name: string
          invited_at: string
          user_id: string
        }[]
      }
      mark_session_mailbox_delivered: {
        Args: { p_item_ids: string[]; p_session_id: string }
        Returns: number
      }
      mint_device_grant_from_family: {
        Args: {
          p_app_kind: string
          p_device_name: string
          p_device_public_key: string
          p_family_token_hash: string
          p_grant_id: string
          p_grant_kind: string
          p_scopes: Json
          p_subject_id: string
          p_token_hash: string
        }
        Returns: Json
      }
      normalize_email: { Args: { p_email: string }; Returns: string }
      open_crew_conv: {
        Args: { p_responsible_subject_id: string; p_title?: string }
        Returns: string
      }
      open_crew_conv_for_subject: {
        Args: {
          p_actor_user_id: string
          p_responsible_subject_id: string
          p_title?: string
        }
        Returns: string
      }
      open_crew_session: {
        Args: {
          p_crew_conversation_id: string
          p_runner_kind: string
          p_task_brief: string
        }
        Returns: string
      }
      open_crew_session_by_captain: {
        Args: {
          p_captain_bot_id: string
          p_crew_conversation_id: string
          p_runner_kind?: string
          p_task_brief: string
        }
        Returns: string
      }
      open_crew_session_for_subject: {
        Args: {
          p_actor_user_id: string
          p_crew_conversation_id: string
          p_responsible_subject_id: string
          p_runner_kind: string
          p_task_brief: string
        }
        Returns: string
      }
      open_group_conv: {
        Args: {
          p_initial_bot_ids: string[]
          p_initial_user_ids: string[]
          p_title: string
        }
        Returns: string
      }
      open_self_conv: { Args: never; Returns: string }
      open_user_bot_conv: { Args: { p_bot_id: string }; Returns: string }
      open_user_user_conv: { Args: { p_other_user_id: string }; Returns: Json }
      random_place_name: { Args: never; Returns: string }
      register_runner_host: {
        Args: {
          p_allowed_runner_kinds?: Json
          p_capabilities?: Json
          p_display_name: string
          p_responsible_subject_id: string
        }
        Returns: string
      }
      request_account_deletion: {
        Args: { p_sentiment: string }
        Returns: undefined
      }
      resolve_crew_responsibility_shares: {
        Args: { p_crew_conversation_id: string }
        Returns: {
          share_bps: number
          source: string
          subject_id: string
        }[]
      }
      revoke_family_sso_credential: {
        Args: { p_family_id: string }
        Returns: undefined
      }
      runner_host_heartbeat: {
        Args: {
          p_allowed_runner_kinds?: Json
          p_capabilities?: Json
          p_runner_host_id: string
        }
        Returns: boolean
      }
      runner_host_heartbeat_for_subject: {
        Args: {
          p_allowed_runner_kinds?: Json
          p_capabilities?: Json
          p_responsible_subject_id: string
          p_runner_host_id: string
        }
        Returns: boolean
      }
      seed_example_letter: { Args: { p_user_id: string }; Returns: undefined }
      seed_sample_dialogue: {
        Args: {
          p_bot_id: string
          p_conv_id: string
          p_slug: string
          p_user_id: string
        }
        Returns: undefined
      }
      start_user_bot_turn: {
        Args: {
          p_attachment_ids?: string[]
          p_bot_id: string
          p_client_message_id: string
          p_content: string
        }
        Returns: Json
      }
      subject_can_authorize_device_grant: {
        Args: { p_grant_kind: string; p_subject_id: string; p_user_id: string }
        Returns: boolean
      }
      subject_can_create_crew: {
        Args: { p_subject_id: string; p_user_id: string }
        Returns: boolean
      }
      subject_can_manage_runners: {
        Args: { p_subject_id: string; p_user_id: string }
        Returns: boolean
      }
      subject_has_user_access: {
        Args: { p_subject_id: string; p_user_id: string }
        Returns: boolean
      }
      subject_user_has_role: {
        Args: { p_roles: string[]; p_subject_id: string; p_user_id: string }
        Returns: boolean
      }
      upsert_self_machine: {
        Args: {
          p_device_id: string
          p_display_name: string
          p_subject_id: string
        }
        Returns: string
      }
      user_can_control_crew_by_responsibility: {
        Args: { p_crew_conversation_id: string; p_user_id: string }
        Returns: boolean
      }
      user_has_conv_with_bot: {
        Args: { p_bot_id: string; p_user_id: string }
        Returns: boolean
      }
      uuidv7: { Args: never; Returns: string }
    }
    Enums: {
      continue_request_status: "pending" | "allowed" | "denied" | "expired"
      group_join_policy: "scan_open" | "approval" | "closed"
      group_split_mode:
        | "custom"
        | "per_head"
        | "per_message"
        | "per_token"
        | "hybrid"
      join_request_status: "pending" | "approved" | "rejected" | "expired"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  pendingbot: {
    Enums: {
      continue_request_status: ["pending", "allowed", "denied", "expired"],
      group_join_policy: ["scan_open", "approval", "closed"],
      group_split_mode: [
        "custom",
        "per_head",
        "per_message",
        "per_token",
        "hybrid",
      ],
      join_request_status: ["pending", "approved", "rejected", "expired"],
    },
  },
} as const
