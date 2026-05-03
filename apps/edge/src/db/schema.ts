// Database type generated from supabase/migrations + seeds.
// To regenerate (after a migration change):
//   supabase start
//   supabase db reset --local
//   supabase gen types typescript --local --schema pendingbot \
//     > apps/edge/src/db/schema.ts
//
// Do not hand-edit — anything below this header is overwritten.
export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  pendingbot: {
    Tables: {
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
          cache_read_tokens: number
          cache_write_tokens: number
          conversation_id: string | null
          cost_usd: number | null
          created_at: string
          generation_id: string | null
          id: string
          input_tokens: number
          latency_ms: number | null
          metadata: Json
          model_id: string
          output_tokens: number
          tag: string | null
          task_type: string
          total_tokens: number
          user_id: string | null
        }
        Insert: {
          cache_read_tokens?: number
          cache_write_tokens?: number
          conversation_id?: string | null
          cost_usd?: number | null
          created_at?: string
          generation_id?: string | null
          id?: string
          input_tokens?: number
          latency_ms?: number | null
          metadata?: Json
          model_id: string
          output_tokens?: number
          tag?: string | null
          task_type: string
          total_tokens?: number
          user_id?: string | null
        }
        Update: {
          cache_read_tokens?: number
          cache_write_tokens?: number
          conversation_id?: string | null
          cost_usd?: number | null
          created_at?: string
          generation_id?: string | null
          id?: string
          input_tokens?: number
          latency_ms?: number | null
          metadata?: Json
          model_id?: string
          output_tokens?: number
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
      messages: {
        Row: {
          attachments: Json | null
          bubble_group_id: string | null
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
          bio: string | null
          created_at: string
          custom_fields: Json
          display_name: string
          email: string | null
          id: string
          is_admin: boolean
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
          is_admin?: boolean
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
          is_admin?: boolean
          updated_at?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      _delete_account_internal: { Args: { p_uid: string }; Returns: undefined }
      bootstrap_user_id: {
        Args: { p_email: string; p_meta: Json; p_uid: string }
        Returns: undefined
      }
      bot_invites_add: {
        Args: { p_bot_id: string; p_handle: string }
        Returns: string
      }
      delete_self_account: { Args: never; Returns: undefined }
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

