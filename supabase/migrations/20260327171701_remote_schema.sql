


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."handle_new_registered_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    INSERT INTO public.profiles (
        id, email, full_name, nickname, rank_name, e_stars, is_registered, upgrades_used
    )
    VALUES (
        NEW.id::VARCHAR,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'name', 'Người dùng mới'),
        COALESCE(NEW.raw_user_meta_data->>'nickname', ''),
        'Member',
        50.0000,
        TRUE,
        0
    )
    ON CONFLICT (id) DO UPDATE SET 
        email = EXCLUDED.email, 
        full_name = EXCLUDED.full_name,
        nickname = COALESCE(public.profiles.nickname, EXCLUDED.nickname),
        is_registered = TRUE;

    INSERT INTO public.user_usage (user_id, cycle_start_date)
    VALUES (NEW.id::VARCHAR, NOW())
    ON CONFLICT (user_id) DO NOTHING;

    RETURN NEW;
EXCEPTION
    WHEN OTHERS THEN
        RAISE LOG 'Lỗi Trigger tạo Profile: %', SQLERRM;
        RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_registered_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_media_transaction"("p_user_id" character varying, "p_media_type" character varying, "p_estar_cost" numeric, "p_estimated_size_bytes" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_profile RECORD;
    v_usage RECORD;
    v_is_quota_available BOOLEAN := FALSE;
    v_actual_estar_deducted NUMERIC(15, 4) := 0.0000;
    v_actual_quota_deducted INT := 0;
BEGIN
    SELECT p.*, r.quota_image, r.quota_video, r.cloud_limit_mb 
    INTO v_profile 
    FROM public.profiles p JOIN public.rank_limits r ON p.rank_name = r.rank_name WHERE p.id = p_user_id;
    
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Không tìm thấy người dùng.'); END IF;

    SELECT * INTO v_usage FROM public.user_usage WHERE user_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Không tìm thấy dữ liệu.'); END IF;

    IF v_usage.cycle_start_date + INTERVAL '30 days' < NOW() THEN
        UPDATE public.user_usage SET images_used = 0, videos_used = 0, cycle_start_date = NOW() WHERE user_id = p_user_id RETURNING * INTO v_usage;
    END IF;

    IF v_profile.rank_name != 'Admin' THEN
        IF (v_usage.storage_bytes_used + p_estimated_size_bytes) > (v_profile.cloud_limit_mb * 1024 * 1024) THEN
            RETURN jsonb_build_object('success', false, 'error', 'Vượt quá dung lượng Cloud.');
        END IF;
    END IF;

    IF p_media_type = 'image' THEN
        IF v_usage.images_used < v_profile.quota_image OR v_profile.rank_name = 'Admin' THEN v_is_quota_available := TRUE; v_actual_quota_deducted := 1; END IF;
    ELSIF p_media_type = 'video' THEN
        IF v_usage.videos_used < v_profile.quota_video OR v_profile.rank_name = 'Admin' THEN v_is_quota_available := TRUE; v_actual_quota_deducted := 1; END IF;
    ELSIF p_media_type = 'chatbot' THEN
        v_is_quota_available := FALSE; -- Chatbot luôn trừ E-Star, không dùng Quota
    ELSE 
        RETURN jsonb_build_object('success', false, 'error', 'Loại hình giao dịch không hợp lệ.'); 
    END IF;

    IF v_is_quota_available THEN
        IF p_media_type = 'image' THEN UPDATE public.user_usage SET images_used = images_used + 1, updated_at = NOW() WHERE user_id = p_user_id;
        ELSE UPDATE public.user_usage SET videos_used = videos_used + 1, updated_at = NOW() WHERE user_id = p_user_id; END IF;
    ELSE
        IF v_profile.e_stars >= p_estar_cost THEN 
            UPDATE public.profiles SET e_stars = e_stars - p_estar_cost, updated_at = NOW() WHERE id = p_user_id; 
            v_actual_estar_deducted := p_estar_cost;
        ELSE 
            RETURN jsonb_build_object('success', false, 'error', 'Hết Quota và không đủ E-Star.'); 
        END IF;
    END IF;

    INSERT INTO public.transaction_logs (user_id, action_type, quota_deducted, estar_deducted, description)
    VALUES (p_user_id, 'create_' || p_media_type, v_actual_quota_deducted, v_actual_estar_deducted, 'Khởi tạo ' || p_media_type || CASE WHEN v_is_quota_available THEN ' (Trừ Quota)' ELSE ' (Trừ E-Star)' END);

    RETURN jsonb_build_object('success', true, 'used_quota', v_is_quota_available, 'estar_deducted', v_actual_estar_deducted);
END;
$$;


ALTER FUNCTION "public"."process_media_transaction"("p_user_id" character varying, "p_media_type" character varying, "p_estar_cost" numeric, "p_estimated_size_bytes" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_monthly_estar_reset"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    UPDATE public.profiles p
    SET e_stars = e_stars + r.e_stars_monthly
    FROM public.rank_limits r
    WHERE p.rank_name = r.rank_name;
END;
$$;


ALTER FUNCTION "public"."rpc_monthly_estar_reset"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_remove_user"("p_admin_id" character varying, "p_target_id" character varying) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_admin RECORD;
    v_target RECORD;
    v_days INT;
BEGIN
    SELECT * INTO v_admin FROM public.profiles WHERE id = p_admin_id;
    SELECT * INTO v_target FROM public.profiles WHERE id = p_target_id;

    IF v_admin.rank_name != 'Admin' THEN
        IF v_target.invited_by != p_admin_id THEN RETURN jsonb_build_object('success', false, 'error', 'Không có thẩm quyền thu hồi.'); END IF;
        v_days := EXTRACT(DAY FROM (NOW() - v_target.invited_at));
        IF v_days < 15 THEN RETURN jsonb_build_object('success', false, 'error', 'Chưa qua thời gian khóa 15 ngày.'); END IF;
    END IF;

    UPDATE public.profiles SET rank_name = 'Member', invited_by = NULL, invited_at = NULL WHERE id = p_target_id;
    RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."rpc_remove_user"("p_admin_id" character varying, "p_target_id" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_upgrade_user"("p_admin_id" character varying, "p_target_email" character varying, "p_target_rank" character varying) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_admin RECORD;
    v_target RECORD;
    v_invited_count INT;
    v_old_rank_estars NUMERIC(15,4);
    v_new_rank_estars NUMERIC(15,4);
    v_estar_diff NUMERIC(15,4);
BEGIN
    SELECT p.*, r.upgrade_slots INTO v_admin FROM public.profiles p JOIN public.rank_limits r ON p.rank_name = r.rank_name WHERE p.id = p_admin_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Tài khoản cấp quyền không hợp lệ.'); END IF;
    
    SELECT p.* INTO v_target FROM public.profiles p WHERE email = p_target_email;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Không tìm thấy tài khoản với Email này.'); END IF;

    IF v_target.id = p_admin_id THEN RETURN jsonb_build_object('success', false, 'error', 'Không thể tự nâng cấp chính mình.'); END IF;

    IF v_admin.rank_name != 'Admin' THEN
        IF v_admin.rank_name NOT IN ('Teams', 'SME') THEN RETURN jsonb_build_object('success', false, 'error', 'Bạn không có thẩm quyền.'); END IF;
        IF p_target_rank != 'MemberPro' THEN RETURN jsonb_build_object('success', false, 'error', 'Chỉ được phép cấp quyền MemberPro.'); END IF;
        IF v_target.invited_by IS NOT NULL AND v_target.invited_by != p_admin_id THEN RETURN jsonb_build_object('success', false, 'error', 'Tài khoản này đang thuộc tổ chức khác.'); END IF;
        IF v_target.rank_name IN ('Admin', 'Dev') THEN RETURN jsonb_build_object('success', false, 'error', 'Không thể thay đổi quyền hệ thống.'); END IF;
        
        SELECT count(*) INTO v_invited_count FROM public.profiles WHERE invited_by = p_admin_id;
        IF v_invited_count >= v_admin.upgrade_slots THEN RETURN jsonb_build_object('success', false, 'error', 'Đã hết Slot cấp quyền.'); END IF;
    END IF;

    SELECT e_stars_monthly INTO v_old_rank_estars FROM public.rank_limits WHERE rank_name = v_target.rank_name;
    SELECT e_stars_monthly INTO v_new_rank_estars FROM public.rank_limits WHERE rank_name = p_target_rank;
    
    v_estar_diff := COALESCE(v_new_rank_estars, 50.0000) - COALESCE(v_old_rank_estars, 50.0000);

    UPDATE public.profiles 
    SET rank_name = p_target_rank, 
        invited_by = p_admin_id, 
        invited_at = NOW(),
        e_stars = GREATEST(0.0000, e_stars + v_estar_diff)
    WHERE id = v_target.id;
    
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('id', v_target.id, 'email', v_target.email, 'full_name', v_target.full_name, 'avatar_url', v_target.avatar_url, 'rank_name', p_target_rank, 'invited_at', NOW()));
END;
$$;


ALTER FUNCTION "public"."rpc_upgrade_user"("p_admin_id" character varying, "p_target_email" character varying, "p_target_rank" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_workspace_sessions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = timezone('utc', now());
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_workspace_sessions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_cloud_storage_usage"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.user_usage 
        SET storage_bytes_used = storage_bytes_used + NEW.file_size_bytes,
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.user_usage 
        SET storage_bytes_used = GREATEST(storage_bytes_used - OLD.file_size_bytes, 0),
            updated_at = NOW()
        WHERE user_id = OLD.user_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_cloud_storage_usage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_session_cloud_storage_usage"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_diff BIGINT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.user_usage 
        SET storage_bytes_used = storage_bytes_used + NEW.size_bytes,
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        v_diff := NEW.size_bytes - OLD.size_bytes;
        IF v_diff != 0 THEN
            UPDATE public.user_usage 
            SET storage_bytes_used = GREATEST(storage_bytes_used + v_diff, 0),
                updated_at = NOW()
            WHERE user_id = NEW.user_id;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.user_usage 
        SET storage_bytes_used = GREATEST(storage_bytes_used - OLD.size_bytes, 0),
            updated_at = NOW()
        WHERE user_id = OLD.user_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_session_cloud_storage_usage"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."aue_art_projects" (
    "id" character varying(255) NOT NULL,
    "user_id" character varying(255) NOT NULL,
    "name" character varying(255) NOT NULL,
    "image_draft" "jsonb" DEFAULT '{"prompt": "", "negativePrompt": ""}'::"jsonb",
    "video_draft" "jsonb" DEFAULT '{"prompt": "", "negativePrompt": ""}'::"jsonb",
    "image_results" "jsonb" DEFAULT '[]'::"jsonb",
    "video_results" "jsonb" DEFAULT '[]'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."aue_art_projects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."aue_kv_store" (
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL
);


ALTER TABLE "public"."aue_kv_store" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."media_files" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" character varying(255) NOT NULL,
    "workspace_type" character varying(50) DEFAULT 'art'::character varying,
    "file_type" character varying(50),
    "file_url" "text" NOT NULL,
    "file_size_bytes" bigint DEFAULT 0 NOT NULL,
    "model_used" character varying(100),
    "prompt_used" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "media_files_file_type_check" CHECK ((("file_type")::"text" = ANY ((ARRAY['image'::character varying, 'video'::character varying, 'document'::character varying, 'audio'::character varying])::"text"[])))
);


ALTER TABLE "public"."media_files" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" character varying(255) NOT NULL,
    "email" character varying(255),
    "full_name" character varying(255),
    "nickname" character varying(255),
    "avatar_url" "text",
    "country" character varying(100),
    "city" character varying(100),
    "address" "text",
    "zalo" character varying(50),
    "telegram" character varying(50),
    "facebook" "text",
    "website" "text",
    "user_role" character varying(100),
    "bio" "text",
    "survey_data" "jsonb" DEFAULT '{}'::"jsonb",
    "survey_completed" boolean DEFAULT false,
    "rank_name" character varying(50) DEFAULT 'Guest'::character varying,
    "e_stars" numeric(15,4) DEFAULT 0.0000,
    "upgrades_used" integer DEFAULT 0,
    "invited_by" character varying(255),
    "invited_at" timestamp with time zone,
    "is_registered" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rank_limits" (
    "rank_name" character varying(50) NOT NULL,
    "quota_image" integer NOT NULL,
    "quota_video" integer NOT NULL,
    "cloud_limit_mb" integer NOT NULL,
    "upgrade_slots" integer DEFAULT 0 NOT NULL,
    "e_stars_monthly" numeric(15,4) DEFAULT 50.0000,
    "description" "text"
);


ALTER TABLE "public"."rank_limits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transaction_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" character varying(255) NOT NULL,
    "action_type" character varying(100) NOT NULL,
    "quota_deducted" integer DEFAULT 0,
    "estar_deducted" numeric(15,4) DEFAULT 0.0000,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."transaction_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_usage" (
    "user_id" character varying(255) NOT NULL,
    "cycle_start_date" timestamp with time zone DEFAULT "now"(),
    "images_used" integer DEFAULT 0,
    "videos_used" integer DEFAULT 0,
    "storage_bytes_used" bigint DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workspace_sessions" (
    "id" bigint NOT NULL,
    "user_id" character varying(255) NOT NULL,
    "scope" "text" NOT NULL,
    "session_id" "text" NOT NULL,
    "title" "text" DEFAULT 'New Chat'::"text" NOT NULL,
    "role_key" "text",
    "folder_id" "text",
    "model" "text",
    "messages_json" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "size_bytes" bigint DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."workspace_sessions" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."workspace_sessions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."workspace_sessions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."workspace_sessions_id_seq" OWNED BY "public"."workspace_sessions"."id";



ALTER TABLE ONLY "public"."workspace_sessions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."workspace_sessions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."aue_art_projects"
    ADD CONSTRAINT "aue_art_projects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."aue_kv_store"
    ADD CONSTRAINT "aue_kv_store_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."media_files"
    ADD CONSTRAINT "media_files_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rank_limits"
    ADD CONSTRAINT "rank_limits_pkey" PRIMARY KEY ("rank_name");



ALTER TABLE ONLY "public"."transaction_logs"
    ADD CONSTRAINT "transaction_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_usage"
    ADD CONSTRAINT "user_usage_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."workspace_sessions"
    ADD CONSTRAINT "workspace_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workspace_sessions"
    ADD CONSTRAINT "workspace_sessions_user_id_scope_session_id_key" UNIQUE ("user_id", "scope", "session_id");



CREATE INDEX "idx_workspace_sessions_user_scope_session_id" ON "public"."workspace_sessions" USING "btree" ("user_id", "scope", "session_id");



CREATE INDEX "idx_workspace_sessions_user_scope_updated_at" ON "public"."workspace_sessions" USING "btree" ("user_id", "scope", "updated_at" DESC);



CREATE OR REPLACE TRIGGER "on_media_file_change" AFTER INSERT OR DELETE ON "public"."media_files" FOR EACH ROW EXECUTE FUNCTION "public"."update_cloud_storage_usage"();



CREATE OR REPLACE TRIGGER "on_workspace_session_change" AFTER INSERT OR DELETE OR UPDATE ON "public"."workspace_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."update_session_cloud_storage_usage"();



CREATE OR REPLACE TRIGGER "trg_workspace_sessions_updated_at" BEFORE UPDATE ON "public"."workspace_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."set_workspace_sessions_updated_at"();



ALTER TABLE ONLY "public"."aue_art_projects"
    ADD CONSTRAINT "aue_art_projects_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."media_files"
    ADD CONSTRAINT "media_files_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_rank_name_fkey" FOREIGN KEY ("rank_name") REFERENCES "public"."rank_limits"("rank_name");



ALTER TABLE ONLY "public"."transaction_logs"
    ADD CONSTRAINT "transaction_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_usage"
    ADD CONSTRAINT "user_usage_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."workspace_sessions"
    ADD CONSTRAINT "workspace_sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



CREATE POLICY "Cho phep doc tat ca Profile" ON "public"."profiles" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Public read access for rank limits" ON "public"."rank_limits" FOR SELECT USING (true);



CREATE POLICY "Users can delete own art projects" ON "public"."aue_art_projects" FOR DELETE USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can delete own media" ON "public"."media_files" FOR DELETE USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can delete own workspace sessions" ON "public"."workspace_sessions" FOR DELETE USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can insert own art projects" ON "public"."aue_art_projects" FOR INSERT WITH CHECK ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can insert own media" ON "public"."media_files" FOR INSERT WITH CHECK ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can insert own workspace sessions" ON "public"."workspace_sessions" FOR INSERT WITH CHECK ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can update own art projects" ON "public"."aue_art_projects" FOR UPDATE USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can update own workspace sessions" ON "public"."workspace_sessions" FOR UPDATE USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can update their own profile" ON "public"."profiles" FOR UPDATE USING ((("id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can view own art projects" ON "public"."aue_art_projects" FOR SELECT USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can view own media" ON "public"."media_files" FOR SELECT USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can view own transactions" ON "public"."transaction_logs" FOR SELECT USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can view own usage" ON "public"."user_usage" FOR SELECT USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



CREATE POLICY "Users can view own workspace sessions" ON "public"."workspace_sessions" FOR SELECT USING ((("user_id")::"text" = ("auth"."uid"())::"text"));



ALTER TABLE "public"."aue_art_projects" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."media_files" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rank_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transaction_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_usage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."workspace_sessions" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."handle_new_registered_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_registered_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_registered_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_media_transaction"("p_user_id" character varying, "p_media_type" character varying, "p_estar_cost" numeric, "p_estimated_size_bytes" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."process_media_transaction"("p_user_id" character varying, "p_media_type" character varying, "p_estar_cost" numeric, "p_estimated_size_bytes" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_media_transaction"("p_user_id" character varying, "p_media_type" character varying, "p_estar_cost" numeric, "p_estimated_size_bytes" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_monthly_estar_reset"() TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_monthly_estar_reset"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_monthly_estar_reset"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_remove_user"("p_admin_id" character varying, "p_target_id" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_remove_user"("p_admin_id" character varying, "p_target_id" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_remove_user"("p_admin_id" character varying, "p_target_id" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."rpc_upgrade_user"("p_admin_id" character varying, "p_target_email" character varying, "p_target_rank" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_upgrade_user"("p_admin_id" character varying, "p_target_email" character varying, "p_target_rank" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_upgrade_user"("p_admin_id" character varying, "p_target_email" character varying, "p_target_rank" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_workspace_sessions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_workspace_sessions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_workspace_sessions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_cloud_storage_usage"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_cloud_storage_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_cloud_storage_usage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_session_cloud_storage_usage"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_session_cloud_storage_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_session_cloud_storage_usage"() TO "service_role";


















GRANT ALL ON TABLE "public"."aue_art_projects" TO "anon";
GRANT ALL ON TABLE "public"."aue_art_projects" TO "authenticated";
GRANT ALL ON TABLE "public"."aue_art_projects" TO "service_role";



GRANT ALL ON TABLE "public"."aue_kv_store" TO "anon";
GRANT ALL ON TABLE "public"."aue_kv_store" TO "authenticated";
GRANT ALL ON TABLE "public"."aue_kv_store" TO "service_role";



GRANT ALL ON TABLE "public"."media_files" TO "anon";
GRANT ALL ON TABLE "public"."media_files" TO "authenticated";
GRANT ALL ON TABLE "public"."media_files" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."rank_limits" TO "anon";
GRANT ALL ON TABLE "public"."rank_limits" TO "authenticated";
GRANT ALL ON TABLE "public"."rank_limits" TO "service_role";



GRANT ALL ON TABLE "public"."transaction_logs" TO "anon";
GRANT ALL ON TABLE "public"."transaction_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."transaction_logs" TO "service_role";



GRANT ALL ON TABLE "public"."user_usage" TO "anon";
GRANT ALL ON TABLE "public"."user_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."user_usage" TO "service_role";



GRANT ALL ON TABLE "public"."workspace_sessions" TO "anon";
GRANT ALL ON TABLE "public"."workspace_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."workspace_sessions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."workspace_sessions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."workspace_sessions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."workspace_sessions_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































drop extension if exists "pg_net";

alter table "public"."media_files" drop constraint "media_files_file_type_check";

alter table "public"."media_files" add constraint "media_files_file_type_check" CHECK (((file_type)::text = ANY ((ARRAY['image'::character varying, 'video'::character varying, 'document'::character varying, 'audio'::character varying])::text[]))) not valid;

alter table "public"."media_files" validate constraint "media_files_file_type_check";

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_registered_user();


