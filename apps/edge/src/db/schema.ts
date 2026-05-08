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
      admin_audit: {
        Row: {
          action: string
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
      ai_picks: {
        Row: {
          created_at: string
          id: string
          metadata: Json
          source: string | null
          summary: string | null
          title: string | null
          url: string | null
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          metadata?: Json
          source?: string | null
          summary?: string | null
          title?: string | null
          url?: string | null
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          metadata?: Json
          source?: string | null
          summary?: string | null
          title?: string | null
          url?: string | null
          user_id?: string
        }
        Relationships: []
      }
      attachments: {
        Row: {
          byte_size: number
          conversation_id: string | null
          created_at: string
          height: number | null
          id: string
          metadata: Json
          mime_type: string
          r2_key: string
          thumb_r2_key: string | null
          user_id: string
          width: number | null
        }
        Insert: {
          byte_size: number
          conversation_id?: string | null
          created_at?: string
          height?: number | null
          id?: string
          metadata?: Json
          mime_type: string
          r2_key: string
          thumb_r2_key?: string | null
          user_id: string
          width?: number | null
        }
        Update: {
          byte_size?: number
          conversation_id?: string | null
          created_at?: string
          height?: number | null
          id?: string
          metadata?: Json
          mime_type?: string
          r2_key?: string
          thumb_r2_key?: string | null
          user_id?: string
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
          model_alias_id: string | null
          model_id: string
          output_tokens: number
          provider_id: string | null
          route_trace: Json | null
          status: string | null
          tag: string | null
          task_type: string
          total_tokens: number
          user_id: string | null
        }
        Insert: {
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
          model_alias_id?: string | null
          model_id: string
          output_tokens?: number
          provider_id?: string | null
          route_trace?: Json | null
          status?: string | null
          tag?: string | null
          task_type: string
          total_tokens?: number
          user_id?: string | null
        }
        Update: {
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
          model_alias_id?: string | null
          model_id?: string
          output_tokens?: number
          provider_id?: string | null
          route_trace?: Json | null
          status?: string | null
          tag?: string | null
          task_type?: string
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
          {
            foreignKeyName: "audit_log_model_alias_id_fkey"
            columns: ["model_alias_id"]
            isOneToOne: false
            referencedRelation: "llm_model_aliases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_log_provider_id_fkey"
            columns: ["provider_id"]
            isOneToOne: false
            referencedRelation: "llm_providers"
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
      billing_ledger: {
        Row: {
          actor_user_id: string | null
          created_at: string
          delta_credits: number
          entry_type: string
          id: string
          metadata: Json
          reason: string | null
          redemption_id: string | null
          topup_id: string | null
          user_id: string
        }
        Insert: {
          actor_user_id?: string | null
          created_at?: string
          delta_credits: number
          entry_type: string
          id?: string
          metadata?: Json
          reason?: string | null
          redemption_id?: string | null
          topup_id?: string | null
          user_id: string
        }
        Update: {
          actor_user_id?: string | null
          created_at?: string
          delta_credits?: number
          entry_type?: string
          id?: string
          metadata?: Json
          reason?: string | null
          redemption_id?: string | null
          topup_id?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "billing_ledger_redemption_id_fkey"
            columns: ["redemption_id"]
            isOneToOne: false
            referencedRelation: "redemption_codes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "billing_ledger_topup_id_fkey"
            columns: ["topup_id"]
            isOneToOne: false
            referencedRelation: "topups"
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
      bot_reflections: {
        Row: {
          bot_id: string
          content: string
          created_at: string
          id: string
          kind: string
          review_run_id: string | null
          user_id: string
        }
        Insert: {
          bot_id: string
          content: string
          created_at?: string
          id?: string
          kind: string
          review_run_id?: string | null
          user_id: string
        }
        Update: {
          bot_id?: string
          content?: string
          created_at?: string
          id?: string
          kind?: string
          review_run_id?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bot_reflections_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
        ]
      }
      bot_sandbox_sessions: {
        Row: {
          bootstrapped: boolean
          conversation_id: string
          created_at: string
          daytona_sandbox_id: string
          id: string
          last_used_at: string
        }
        Insert: {
          bootstrapped?: boolean
          conversation_id: string
          created_at?: string
          daytona_sandbox_id: string
          id?: string
          last_used_at?: string
        }
        Update: {
          bootstrapped?: boolean
          conversation_id?: string
          created_at?: string
          daytona_sandbox_id?: string
          id?: string
          last_used_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bot_sandbox_sessions_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: true
            referencedRelation: "conversations"
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
          output_mode: string
          slug: string
          updated_at: string
          visibility: string
        }
        Insert: {
          config?: Json
          created_at?: string
          creator_id?: string | null
          display_name: string
          id?: string
          is_active?: boolean
          model_id: string
          output_mode?: string
          slug: string
          updated_at?: string
          visibility?: string
        }
        Update: {
          config?: Json
          created_at?: string
          creator_id?: string | null
          display_name?: string
          id?: string
          is_active?: boolean
          model_id?: string
          output_mode?: string
          slug?: string
          updated_at?: string
          visibility?: string
        }
        Relationships: []
      }
      conversation_participants: {
        Row: {
          conversation_id: string
          joined_at: string
          last_read_message_id: string | null
          participant_id: string
          participant_type: string
          role: string
        }
        Insert: {
          conversation_id: string
          joined_at?: string
          last_read_message_id?: string | null
          participant_id: string
          participant_type: string
          role?: string
        }
        Update: {
          conversation_id?: string
          joined_at?: string
          last_read_message_id?: string | null
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
          feature: string
          id: string
          last_turn_status: string | null
          metadata: Json
          provider_override: string | null
          round_count: number
          title: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          bot_id?: string | null
          conversation_type?: string
          created_at?: string
          feature?: string
          id?: string
          last_turn_status?: string | null
          metadata?: Json
          provider_override?: string | null
          round_count?: number
          title?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          bot_id?: string | null
          conversation_type?: string
          created_at?: string
          feature?: string
          id?: string
          last_turn_status?: string | null
          metadata?: Json
          provider_override?: string | null
          round_count?: number
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
        ]
      }
      device_tokens: {
        Row: {
          created_at: string
          endpoint: string | null
          id: string
          is_active: boolean
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
          last_used_at?: string | null
          metadata?: Json
          platform?: string
          token?: string
          user_id?: string
        }
        Relationships: []
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
      llm_model_aliases: {
        Row: {
          cache_write_price: number | null
          cached_input_price: number | null
          config: Json
          created_at: string
          currency: string
          enabled: boolean
          id: string
          input_price: number
          model_id: string
          notes: string | null
          output_price: number
          provider_id: string
          provider_model_id: string
          updated_at: string
          weight: number
        }
        Insert: {
          cache_write_price?: number | null
          cached_input_price?: number | null
          config?: Json
          created_at?: string
          currency?: string
          enabled?: boolean
          id?: string
          input_price: number
          model_id: string
          notes?: string | null
          output_price: number
          provider_id: string
          provider_model_id: string
          updated_at?: string
          weight?: number
        }
        Update: {
          cache_write_price?: number | null
          cached_input_price?: number | null
          config?: Json
          created_at?: string
          currency?: string
          enabled?: boolean
          id?: string
          input_price?: number
          model_id?: string
          notes?: string | null
          output_price?: number
          provider_id?: string
          provider_model_id?: string
          updated_at?: string
          weight?: number
        }
        Relationships: [
          {
            foreignKeyName: "llm_model_aliases_model_id_fkey"
            columns: ["model_id"]
            isOneToOne: false
            referencedRelation: "llm_models"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "llm_model_aliases_provider_id_fkey"
            columns: ["provider_id"]
            isOneToOne: false
            referencedRelation: "llm_providers"
            referencedColumns: ["id"]
          },
        ]
      }
      llm_models: {
        Row: {
          capabilities: Json
          context_window: number | null
          created_at: string
          deprecated_at: string | null
          display_name: string
          enabled: boolean
          family: string | null
          id: string
          max_output_tokens: number | null
          notes: string | null
          slug: string
          updated_at: string
        }
        Insert: {
          capabilities?: Json
          context_window?: number | null
          created_at?: string
          deprecated_at?: string | null
          display_name: string
          enabled?: boolean
          family?: string | null
          id?: string
          max_output_tokens?: number | null
          notes?: string | null
          slug: string
          updated_at?: string
        }
        Update: {
          capabilities?: Json
          context_window?: number | null
          created_at?: string
          deprecated_at?: string | null
          display_name?: string
          enabled?: boolean
          family?: string | null
          id?: string
          max_output_tokens?: number | null
          notes?: string | null
          slug?: string
          updated_at?: string
        }
        Relationships: []
      }
      llm_providers: {
        Row: {
          auth_type: string
          base_url: string
          config: Json
          created_at: string
          display_name: string
          enabled: boolean
          id: string
          notes: string | null
          priority: number
          secret_ref: string
          slug: string
          updated_at: string
        }
        Insert: {
          auth_type?: string
          base_url: string
          config?: Json
          created_at?: string
          display_name: string
          enabled?: boolean
          id?: string
          notes?: string | null
          priority?: number
          secret_ref: string
          slug: string
          updated_at?: string
        }
        Update: {
          auth_type?: string
          base_url?: string
          config?: Json
          created_at?: string
          display_name?: string
          enabled?: boolean
          id?: string
          notes?: string | null
          priority?: number
          secret_ref?: string
          slug?: string
          updated_at?: string
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
          content_partial: string | null
          content_tsv: unknown
          conversation_id: string
          created_at: string
          id: string
          log_kind: string | null
          log_payload: Json | null
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
          content_partial?: string | null
          content_tsv?: unknown
          conversation_id: string
          created_at?: string
          id?: string
          log_kind?: string | null
          log_payload?: Json | null
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
          content_partial?: string | null
          content_tsv?: unknown
          conversation_id?: string
          created_at?: string
          id?: string
          log_kind?: string | null
          log_payload?: Json | null
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
      model_pricing: {
        Row: {
          cached_input_price: number | null
          currency: string
          input_price: number
          model_id: string
          output_price: number
          updated_at: string
        }
        Insert: {
          cached_input_price?: number | null
          currency?: string
          input_price: number
          model_id: string
          output_price: number
          updated_at?: string
        }
        Update: {
          cached_input_price?: number | null
          currency?: string
          input_price?: number
          model_id?: string
          output_price?: number
          updated_at?: string
        }
        Relationships: []
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
      review_runs: {
        Row: {
          bot_id: string
          conversation_id: string
          created_at: string
          finished_at: string | null
          id: string
          started_at: string | null
          status: string
          trigger: string | null
          user_id: string
        }
        Insert: {
          bot_id: string
          conversation_id: string
          created_at?: string
          finished_at?: string | null
          id?: string
          started_at?: string | null
          status?: string
          trigger?: string | null
          user_id: string
        }
        Update: {
          bot_id?: string
          conversation_id?: string
          created_at?: string
          finished_at?: string | null
          id?: string
          started_at?: string | null
          status?: string
          trigger?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "review_runs_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "review_runs_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      scroll_runs: {
        Row: {
          body_md: string | null
          bot_id: string
          conversation_id: string
          cost_budget_usd: number | null
          cost_used_usd: number
          created_at: string
          finished_at: string | null
          id: string
          progress: Json
          started_at: string | null
          status: string
          summary: string | null
          title: string | null
          trigger: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          body_md?: string | null
          bot_id: string
          conversation_id: string
          cost_budget_usd?: number | null
          cost_used_usd?: number
          created_at?: string
          finished_at?: string | null
          id?: string
          progress?: Json
          started_at?: string | null
          status?: string
          summary?: string | null
          title?: string | null
          trigger?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          body_md?: string | null
          bot_id?: string
          conversation_id?: string
          cost_budget_usd?: number | null
          cost_used_usd?: number
          created_at?: string
          finished_at?: string | null
          id?: string
          progress?: Json
          started_at?: string | null
          status?: string
          summary?: string | null
          title?: string | null
          trigger?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "scroll_runs_bot_id_fkey"
            columns: ["bot_id"]
            isOneToOne: false
            referencedRelation: "bots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scroll_runs_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      skill_subscriptions: {
        Row: {
          conversation_id: string
          installed_at: string
          skill_id: string
          user_id: string
        }
        Insert: {
          conversation_id: string
          installed_at?: string
          skill_id: string
          user_id: string
        }
        Update: {
          conversation_id?: string
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
          created_at: string
          forked_from: string | null
          frontmatter: Json
          id: string
          owner_id: string | null
          updated_at: string
          user_id: string | null
          visibility: string
        }
        Insert: {
          body_md: string
          bot_id?: string | null
          created_at?: string
          forked_from?: string | null
          frontmatter: Json
          id?: string
          owner_id?: string | null
          updated_at?: string
          user_id?: string | null
          visibility?: string
        }
        Update: {
          body_md?: string
          bot_id?: string | null
          created_at?: string
          forked_from?: string | null
          frontmatter?: Json
          id?: string
          owner_id?: string | null
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
            foreignKeyName: "skills_forked_from_fkey"
            columns: ["forked_from"]
            isOneToOne: false
            referencedRelation: "skills"
            referencedColumns: ["id"]
          },
        ]
      }
      task_routing_rules: {
        Row: {
          created_at: string
          enabled: boolean
          id: string
          match_priority: number
          notes: string | null
          override_model_id: string | null
          prefer_provider_id: string | null
          task_type: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          enabled?: boolean
          id?: string
          match_priority?: number
          notes?: string | null
          override_model_id?: string | null
          prefer_provider_id?: string | null
          task_type: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          enabled?: boolean
          id?: string
          match_priority?: number
          notes?: string | null
          override_model_id?: string | null
          prefer_provider_id?: string | null
          task_type?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "task_routing_rules_override_model_fkey"
            columns: ["override_model_id"]
            isOneToOne: false
            referencedRelation: "llm_models"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_routing_rules_prefer_provider_fkey"
            columns: ["prefer_provider_id"]
            isOneToOne: false
            referencedRelation: "llm_providers"
            referencedColumns: ["id"]
          },
        ]
      }
      tools: {
        Row: {
          config_json: Json | null
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          owner_id: string | null
          schema_json: Json
          source_type: string
        }
        Insert: {
          config_json?: Json | null
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          owner_id?: string | null
          schema_json: Json
          source_type: string
        }
        Update: {
          config_json?: Json | null
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          owner_id?: string | null
          schema_json?: Json
          source_type?: string
        }
        Relationships: []
      }
      topups: {
        Row: {
          channel: string
          channel_txn_id: string | null
          created_at: string
          credits_granted: number
          id: string
          is_sandbox: boolean
          notes: string | null
          paid_amount_minor: number | null
          paid_currency: string | null
          raw_receipt: Json | null
          status: string
          user_id: string
          verified_at: string | null
        }
        Insert: {
          channel: string
          channel_txn_id?: string | null
          created_at?: string
          credits_granted: number
          id?: string
          is_sandbox?: boolean
          notes?: string | null
          paid_amount_minor?: number | null
          paid_currency?: string | null
          raw_receipt?: Json | null
          status?: string
          user_id: string
          verified_at?: string | null
        }
        Update: {
          channel?: string
          channel_txn_id?: string | null
          created_at?: string
          credits_granted?: number
          id?: string
          is_sandbox?: boolean
          notes?: string | null
          paid_amount_minor?: number | null
          paid_currency?: string | null
          raw_receipt?: Json | null
          status?: string
          user_id?: string
          verified_at?: string | null
        }
        Relationships: []
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
          unread_count: number
          user_id: string
        }
        Insert: {
          conversation_id: string
          last_message_at?: string | null
          last_message_id?: string | null
          last_message_preview?: string | null
          unread_count?: number
          user_id: string
        }
        Update: {
          conversation_id?: string
          last_message_at?: string | null
          last_message_id?: string | null
          last_message_preview?: string | null
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
          balance_credits: number
          balance_updated_at: string | null
          bio: string | null
          created_at: string
          custom_fields: Json
          display_name: string
          email: string | null
          id: string
          is_admin: boolean
          lifetime_spent_credits: number
          lifetime_topup_credits: number
          updated_at: string
        }
        Insert: {
          avatar_path?: string | null
          balance_credits?: number
          balance_updated_at?: string | null
          bio?: string | null
          created_at?: string
          custom_fields?: Json
          display_name?: string
          email?: string | null
          id: string
          is_admin?: boolean
          lifetime_spent_credits?: number
          lifetime_topup_credits?: number
          updated_at?: string
        }
        Update: {
          avatar_path?: string | null
          balance_credits?: number
          balance_updated_at?: string | null
          bio?: string | null
          created_at?: string
          custom_fields?: Json
          display_name?: string
          email?: string | null
          id?: string
          is_admin?: boolean
          lifetime_spent_credits?: number
          lifetime_topup_credits?: number
          updated_at?: string
        }
        Relationships: []
      }
    }
    Views: {
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
          model_alias_id: string | null
          model_id: string | null
          output_tokens: number | null
          provider_id: string | null
          request_count: number | null
          task_type: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_log_model_alias_id_fkey"
            columns: ["model_alias_id"]
            isOneToOne: false
            referencedRelation: "llm_model_aliases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_log_provider_id_fkey"
            columns: ["provider_id"]
            isOneToOne: false
            referencedRelation: "llm_providers"
            referencedColumns: ["id"]
          },
        ]
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
          provider_id: string | null
          request_count: number | null
          task_type: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_log_provider_id_fkey"
            columns: ["provider_id"]
            isOneToOne: false
            referencedRelation: "llm_providers"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      _delete_account_internal: { Args: { p_uid: string }; Returns: undefined }
      billing_admin_grant: {
        Args: { p_credits: number; p_reason?: string; p_user_id: string }
        Returns: number
      }
      billing_config_int: { Args: { p_key: string }; Returns: number }
      billing_credit: {
        Args: {
          p_actor_user_id?: string
          p_credits: number
          p_kind: string
          p_metadata?: Json
          p_reason?: string
          p_redemption_id?: string
          p_topup_id?: string
          p_user_id: string
        }
        Returns: number
      }
      billing_debit: {
        Args: { p_audit_log_id: string; p_credits: number; p_user_id: string }
        Returns: number
      }
      billing_issue_codes: {
        Args: { p_count: number; p_credits: number; p_label?: string }
        Returns: string[]
      }
      billing_redeem: { Args: { p_code: string }; Returns: Json }
      billing_signup_bonus: { Args: { p_user_id: string }; Returns: number }
      bootstrap_user_id: {
        Args: { p_email: string; p_meta: Json; p_uid: string }
        Returns: undefined
      }
      bot_invites_add: {
        Args: { p_bot_id: string; p_handle: string }
        Returns: string
      }
      delete_self_account: { Args: never; Returns: undefined }
      is_bot_invitee: {
        Args: { p_bot_id: string; p_user_id: string }
        Returns: boolean
      }
      is_participant: { Args: { conv_id: string }; Returns: boolean }
      list_bot_invitees: {
        Args: { p_bot_id: string }
        Returns: {
          display_name: string
          invited_at: string
          user_id: string
        }[]
      }
      open_self_conv: { Args: never; Returns: string }
      open_user_bot_conv: { Args: { p_bot_id: string }; Returns: string }
      random_place_name: { Args: never; Returns: string }
      seed_sample_dialogue: {
        Args: {
          p_bot_id: string
          p_conv_id: string
          p_slug: string
          p_user_id: string
        }
        Returns: undefined
      }
      user_has_conv_with_bot: {
        Args: { p_bot_id: string; p_user_id: string }
        Returns: boolean
      }
      uuidv7: { Args: never; Returns: string }
    }
    Enums: {
      [_ in never]: never
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
    Enums: {},
  },
} as const
