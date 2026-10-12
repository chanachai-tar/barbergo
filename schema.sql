-- =====================================================================
-- BarberGo — Supabase schema (v1)
-- วิธีใช้: Supabase Dashboard → SQL Editor → วางทั้งไฟล์ → Run
-- ครอบคลุม: ผู้ใช้/บทบาท, โปรไฟล์ช่าง+ผลงาน+อุปกรณ์, บริการ, การจอง,
--           ค่าเดินทาง (คำนวณอัตโนมัติ / แคป Grab), แต้มสะสม, รีวิว, KYC, ไฟล์รูป
-- หลักความปลอดภัย: ราคาและยอดเงินคำนวณบนเซิร์ฟเวอร์ (RPC) เท่านั้น
--                  ลูกค้า/ช่างแก้ตัวเลขเงินในตารางเองไม่ได้
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Types ----------
create type user_role     as enum ('customer', 'barber', 'admin');
create type kyc_state     as enum ('pending', 'approved', 'suspended');
create type service_mode  as enum ('onsite', 'home');
create type order_status  as enum ('pending', 'accepted', 'in_progress', 'completed', 'cancelled');
create type travel_state  as enum ('none', 'estimated', 'confirmed');
create type travel_method as enum ('auto', 'grab');

-- =====================================================================
-- PROFILES (ทุกคนที่สมัคร)
-- =====================================================================
create table public.profiles (
    id          uuid primary key references auth.users on delete cascade,
    role        user_role not null default 'customer',
    full_name   text not null default '',
    phone       text,
    avatar_url  text,
    points      int  not null default 0,
    created_at  timestamptz not null default now()
);

-- สร้างโปรไฟล์อัตโนมัติเมื่อสมัคร (ส่ง full_name มาใน user metadata ตอน signUp)
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    insert into public.profiles (id, full_name, phone)
    values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''), new.phone);
    return new;
end $$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- =====================================================================
-- PLATFORM SETTINGS (แถวเดียว — แอดมินแก้)
-- =====================================================================
create table public.platform_settings (
    id                    int primary key default 1 check (id = 1),
    commission_rate       numeric(5,2) not null default 10,
    travel_base_fare      int     not null default 40,   -- ฿ ค่าเริ่มต้น
    travel_base_km        numeric(5,1) not null default 2, -- กม. ที่รวมในค่าเริ่มต้น
    travel_per_km         int     not null default 12,   -- ฿/กม. ถัดไป
    travel_round_trip     boolean not null default true, -- คิดไป-กลับ ×2
    travel_cap            int     not null default 600,  -- เพดานค่าเดินทาง (คำนวณอัตโนมัติ)
    travel_tolerance_pct  int     not null default 30,   -- ยอดแคปเกินค่าคำนวณได้กี่ % ก่อนเตือน
    points_per_baht       numeric(5,3) not null default 0.1, -- 100 บาท = 10 แต้ม
    cancel_window_hours   numeric(4,1) not null default 2,   -- ยกเลิกภายในกี่ชม.ก่อนนัด = กะทันหัน
    cancel_fee_pct        numeric(5,2) not null default 5    -- ค่ายกเลิก % ของค่าบริการ (จ่ายให้ช่าง)
);
insert into public.platform_settings (id) values (1);

-- สูตรเดียวกับในแอป: ต่อเที่ยว = ค่าเริ่มต้น + (กม.เกิน × ฿/กม.) ปัดเศษ, ×2 ถ้าไป-กลับ, ไม่เกินเพดาน
create function public.calc_travel_fee(p_km numeric) returns int
language sql stable set search_path = public as $$
    select least(
        s.travel_cap,
        round(s.travel_base_fare + greatest(0, greatest(coalesce(p_km, 0), 0) - s.travel_base_km) * s.travel_per_km)::int
            * case when s.travel_round_trip then 2 else 1 end
    )
    from public.platform_settings s where s.id = 1;
$$;

-- =====================================================================
-- BARBERS + โปรไฟล์ผลงาน
-- =====================================================================
create table public.barbers (
    id                uuid primary key references public.profiles on delete cascade,
    shop_name         text not null,
    specialty_text    text not null default '',
    specialties       text[] not null default '{}',           -- Fade, Two Block, Mullet, Beard
    service_modes     service_mode[] not null default '{onsite}',
    location_text     text not null default '',
    lat               double precision,
    lng               double precision,
    experience_years  int not null default 0 check (experience_years >= 0),
    bio               text not null default '',
    equipment         text[] not null default '{}',
    kyc_status        kyc_state not null default 'pending',
    is_online         boolean not null default false,
    rating            numeric(2,1) not null default 0,
    reviews_count     int not null default 0,
    created_at        timestamptz not null default now()
);

-- สมัครเป็นช่าง → เปลี่ยนบทบาทเป็น barber อัตโนมัติ
create function public.on_barber_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    update public.profiles set role = 'barber' where id = new.id and role = 'customer';
    return new;
end $$;

create trigger barber_created
    after insert on public.barbers
    for each row execute function public.on_barber_created();

create table public.barber_experience (
    id          uuid primary key default gen_random_uuid(),
    barber_id   uuid not null references public.barbers on delete cascade,
    place       text not null,
    period      text not null,
    description text not null default '',
    sort_order  int  not null default 0
);

create table public.portfolio_items (
    id          uuid primary key default gen_random_uuid(),
    barber_id   uuid not null references public.barbers on delete cascade,
    image_path  text not null,          -- path ใน bucket "portfolio": <barber_id>/<file>.jpg
    caption     text not null default '',
    style       text not null default 'Other',
    created_at  timestamptz not null default now()
);

create table public.services (
    id            uuid primary key default gen_random_uuid(),
    barber_id     uuid not null references public.barbers on delete cascade,
    name          text not null,
    price         int  not null check (price > 0),
    duration_min  int  not null default 40 check (duration_min > 0),
    active        boolean not null default true
);

create table public.kyc_submissions (
    barber_id      uuid primary key references public.barbers on delete cascade,
    id_number      text not null,       -- ข้อมูลส่วนบุคคล (PDPA) — เห็นได้เฉพาะเจ้าของและแอดมิน
    document_path  text not null,       -- path ใน bucket "kyc" (private)
    submitted_at   timestamptz not null default now(),
    reviewed_at    timestamptz,
    reviewer_id    uuid references public.profiles
);

-- =====================================================================
-- ORDERS
-- =====================================================================
create table public.orders (
    id                 uuid primary key default gen_random_uuid(),
    code               text not null unique default ('BG-' || lpad(floor(random() * 1000000)::text, 6, '0')),
    customer_id        uuid not null references public.profiles,
    barber_id          uuid not null references public.barbers,
    type               service_mode not null,
    address            text,
    distance_km        numeric(6,1) not null default 0,
    booking_date       date not null,
    time_slot          text not null,
    subtotal           int not null,                      -- ค่าตัด/บริการ
    travel_fee         int not null default 0,            -- ค่าเดินทาง (ไม่หักคอมมิชชัน)
    grand_total        int generated always as (subtotal + travel_fee) stored,
    travel_status      travel_state not null default 'none',
    travel_method      travel_method,
    travel_app         text,
    travel_proof_path  text,                              -- path ใน bucket "travel-proofs"
    paid_amount        int not null default 0,            -- อัปเดตจาก webhook ระบบชำระเงินเท่านั้น
    payment_method     text not null,
    commission_rate    numeric(5,2) not null,             -- ล็อกอัตรา ณ เวลาจอง
    status             order_status not null default 'pending',
    starts_at          timestamptz not null,              -- เวลาเริ่มนัด (ใช้ตัดสินยกเลิกกะทันหัน)
    cancelled_at       timestamptz,
    cancelled_by       uuid references public.profiles,
    cancel_late        boolean not null default false,
    cancel_travel_charge int not null default 0,          -- ค่าเดินทางที่หักให้ช่าง
    cancel_fee         int not null default 0,            -- ค่ายกเลิก % ที่หักให้ช่าง
    refund_amount      int not null default 0,            -- ยอดที่ต้องคืนลูกค้า (ระบบชำระเงินดำเนินการ)
    created_at         timestamptz not null default now()
);
create index on public.orders (customer_id, created_at desc);
create index on public.orders (barber_id, booking_date);

create table public.order_items (
    id          bigserial primary key,
    order_id    uuid not null references public.orders on delete cascade,
    service_id  uuid references public.services on delete set null,
    name        text not null,
    price       int  not null
);

create table public.reviews (
    order_id     uuid primary key references public.orders on delete cascade,
    customer_id  uuid not null references public.profiles,
    barber_id    uuid not null references public.barbers,
    rating       int not null check (rating between 1 and 5),
    comment      text not null default '',
    created_at   timestamptz not null default now()
);

create function public.refresh_barber_rating() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    update public.barbers b
       set rating        = coalesce((select round(avg(r.rating)::numeric, 1) from public.reviews r where r.barber_id = new.barber_id), 0),
           reviews_count = (select count(*) from public.reviews r where r.barber_id = new.barber_id)
     where b.id = new.barber_id;
    return new;
end $$;

create trigger review_added
    after insert on public.reviews
    for each row execute function public.refresh_barber_rating();

-- =====================================================================
-- RPC: ทุกการเปลี่ยนแปลงที่เกี่ยวกับเงินทำผ่านฟังก์ชันเหล่านี้เท่านั้น
-- =====================================================================

-- ลูกค้าจองคิว — เซิร์ฟเวอร์คิดราคาบริการและค่าเดินทางประมาณการเอง
create function public.create_booking(
    p_barber_id      uuid,
    p_service_ids    uuid[],
    p_type           service_mode,
    p_address        text,
    p_distance_km    numeric,
    p_date           date,
    p_time_slot      text,
    p_payment_method text
) returns public.orders
language plpgsql security definer set search_path = public as $$
declare
    v_barber public.barbers;
    v_sub    int;
    v_fee    int := 0;
    v_rate   numeric;
    v_start  timestamptz;
    v_order  public.orders;
begin
    if auth.uid() is null then raise exception 'not authenticated'; end if;
    if substring(p_time_slot from '\d{1,2}:\d{2}') is null then raise exception 'invalid time slot'; end if;
    v_start := (p_date + substring(p_time_slot from '\d{1,2}:\d{2}')::time) at time zone 'Asia/Bangkok';
    if v_start <= now() then raise exception 'booking time is in the past'; end if;

    select * into v_barber from public.barbers where id = p_barber_id and kyc_status = 'approved';
    if not found then raise exception 'barber not available'; end if;
    if not (p_type = any (v_barber.service_modes)) then raise exception 'service mode not offered'; end if;

    select coalesce(sum(price), 0) into v_sub
      from public.services
     where id = any (p_service_ids) and barber_id = p_barber_id and active;
    if v_sub = 0 then raise exception 'no valid services selected'; end if;

    if p_type = 'home' then
        if coalesce(trim(p_address), '') = '' then raise exception 'address required for home service'; end if;
        v_fee := public.calc_travel_fee(p_distance_km);
    end if;

    select commission_rate into v_rate from public.platform_settings where id = 1;

    insert into public.orders (customer_id, barber_id, type, address, distance_km, booking_date, time_slot,
                               subtotal, travel_fee, travel_status, payment_method, commission_rate, starts_at)
    values (auth.uid(), p_barber_id, p_type,
            case when p_type = 'home' then p_address end,
            case when p_type = 'home' then greatest(coalesce(p_distance_km, 0), 0) else 0 end,
            p_date, p_time_slot, v_sub, v_fee,
            case when p_type = 'home' then 'estimated'::travel_state else 'none'::travel_state end,
            p_payment_method, v_rate, v_start)
    returning * into v_order;

    insert into public.order_items (order_id, service_id, name, price)
    select v_order.id, s.id, s.name, s.price
      from public.services s
     where s.id = any (p_service_ids) and s.barber_id = p_barber_id and s.active;

    return v_order;
end $$;

-- ช่างกดรับงาน + ยืนยันค่าเดินทาง (auto = คิดจากระยะทาง, grab = ตามรูปแคป)
create function public.accept_order(
    p_order_id    uuid,
    p_method      travel_method default 'auto',
    p_distance_km numeric default null,
    p_amount      int default null,
    p_app         text default null,
    p_proof_path  text default null
) returns public.orders
language plpgsql security definer set search_path = public as $$
declare
    v     public.orders;
    v_fee int;
    v_km  numeric;
begin
    select * into v from public.orders where id = p_order_id for update;
    if not found or v.barber_id <> auth.uid() then raise exception 'not your order'; end if;
    if v.status <> 'pending' then raise exception 'order already handled'; end if;

    if v.type = 'home' then
        if p_method = 'auto' then
            v_km  := greatest(coalesce(p_distance_km, v.distance_km), 0);
            v_fee := public.calc_travel_fee(v_km);
        else
            if p_proof_path is null or coalesce(p_amount, 0) <= 0 then
                raise exception 'screenshot and amount required';
            end if;
            if p_proof_path not like auth.uid()::text || '/%' then
                raise exception 'invalid proof path';
            end if;
            v_km  := v.distance_km;
            v_fee := p_amount;
        end if;

        update public.orders
           set travel_fee        = v_fee,
               travel_status     = 'confirmed',
               travel_method     = p_method,
               travel_app        = case when p_method = 'grab' then p_app end,
               travel_proof_path = case when p_method = 'grab' then p_proof_path end,
               distance_km       = v_km,
               status            = 'accepted'
         where id = p_order_id
        returning * into v;
    else
        update public.orders set status = 'accepted' where id = p_order_id returning * into v;
    end if;

    return v;
end $$;

-- ช่างเลื่อนสถานะ: accepted → in_progress → completed (ให้แต้มลูกค้าเมื่อเสร็จ)
create function public.advance_order(p_order_id uuid) returns public.orders
language plpgsql security definer set search_path = public as $$
declare
    v    public.orders;
    v_to order_status;
begin
    select * into v from public.orders where id = p_order_id for update;
    if not found or v.barber_id <> auth.uid() then raise exception 'not your order'; end if;

    v_to := case v.status when 'accepted' then 'in_progress'::order_status
                          when 'in_progress' then 'completed'::order_status end;
    if v_to is null then raise exception 'cannot advance from %', v.status; end if;

    update public.orders set status = v_to where id = p_order_id returning * into v;

    if v_to = 'completed' then
        update public.profiles
           set points = points + floor(v.grand_total * (select points_per_baht from public.platform_settings where id = 1))::int
         where id = v.customer_id;
    end if;
    return v;
end $$;

-- ยกเลิกคิว
--   ลูกค้ายกเลิก: ก่อนช่างรับงาน หรือก่อนนัดเกิน cancel_window_hours → คืนเต็มจำนวน
--                 ช่างรับงานแล้ว + เหลือไม่ถึง window → หักค่าเดินทางที่ยืนยันแล้ว + cancel_fee_pct% ของค่าบริการ ให้ช่าง
--   ช่างยกเลิกเอง: คืนลูกค้าเต็มจำนวนเสมอ
--   แต้มที่ได้จากคิวที่ยกเลิก: ไม่ได้ (แต้มให้ตอนงานเสร็จเท่านั้น)
create function public.cancel_order(p_order_id uuid) returns public.orders
language plpgsql security definer set search_path = public as $$
declare
    v        public.orders;
    s        public.platform_settings;
    v_late   boolean := false;
    v_travel int := 0;
    v_fee    int := 0;
begin
    select * into v from public.orders where id = p_order_id for update;
    if not found or auth.uid() not in (v.customer_id, v.barber_id) then raise exception 'not your order'; end if;
    if v.status not in ('pending', 'accepted') then raise exception 'cannot cancel an order that is %', v.status; end if;

    select * into s from public.platform_settings where id = 1;

    if auth.uid() = v.customer_id and v.status = 'accepted'
       and now() >= v.starts_at - make_interval(secs => s.cancel_window_hours * 3600) then
        v_late   := true;
        v_travel := case when v.type = 'home' and v.travel_status = 'confirmed' then v.travel_fee else 0 end;
        v_fee    := round(v.subtotal * s.cancel_fee_pct / 100)::int;
    end if;

    update public.orders
       set status               = 'cancelled',
           cancelled_at         = now(),
           cancelled_by         = auth.uid(),
           cancel_late          = v_late,
           cancel_travel_charge = v_travel,
           cancel_fee           = v_fee,
           refund_amount        = greatest(v.paid_amount - v_travel - v_fee, 0)
     where id = p_order_id
    returning * into v;
    return v;
end $$;

-- แอดมินอนุมัติ/ระงับ KYC ช่าง
create function public.set_kyc_status(p_barber_id uuid, p_status kyc_state) returns void
language plpgsql security definer set search_path = public as $$
begin
    if not public.is_admin() then raise exception 'admin only'; end if;
    update public.barbers set kyc_status = p_status where id = p_barber_id;
    update public.kyc_submissions set reviewed_at = now(), reviewer_id = auth.uid() where barber_id = p_barber_id;
end $$;

-- =====================================================================
-- COLUMN PRIVILEGES (กันแก้ช่องสำคัญ เช่น role, points, kyc_status, rating)
-- =====================================================================
revoke insert, update on public.profiles from anon, authenticated;
grant  update (full_name, phone, avatar_url) on public.profiles to authenticated;

revoke insert, update on public.barbers from anon, authenticated;
grant  insert (id, shop_name, specialty_text, specialties, service_modes, location_text, lat, lng,
               experience_years, bio, equipment) on public.barbers to authenticated;
grant  update (shop_name, specialty_text, specialties, service_modes, location_text, lat, lng,
               experience_years, bio, equipment, is_online) on public.barbers to authenticated;

revoke insert, update, delete on public.orders, public.order_items from anon, authenticated;
revoke insert, update, delete on public.platform_settings from anon;

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
alter table public.profiles          enable row level security;
alter table public.platform_settings enable row level security;
alter table public.barbers           enable row level security;
alter table public.barber_experience enable row level security;
alter table public.portfolio_items   enable row level security;
alter table public.services          enable row level security;
alter table public.kyc_submissions   enable row level security;
alter table public.orders            enable row level security;
alter table public.order_items       enable row level security;
alter table public.reviews           enable row level security;

-- profiles: เห็นของตัวเอง, ช่าง (สาธารณะ), ลูกค้าในคิวของตัวเอง (สำหรับช่าง), แอดมินเห็นทั้งหมด
create policy "profiles read" on public.profiles for select using (
    id = auth.uid() or role = 'barber' or public.is_admin()
    or exists (select 1 from public.orders o where o.barber_id = auth.uid() and o.customer_id = profiles.id)
);
create policy "profiles update own" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- settings
create policy "settings read"  on public.platform_settings for select using (true);
create policy "settings admin" on public.platform_settings for update using (public.is_admin()) with check (public.is_admin());

-- barbers: สาธารณะเห็นเฉพาะช่างที่อนุมัติแล้ว
create policy "barbers read"       on public.barbers for select using (kyc_status = 'approved' or id = auth.uid() or public.is_admin());
create policy "barbers insert own" on public.barbers for insert with check (id = auth.uid());
create policy "barbers update own" on public.barbers for update using (id = auth.uid()) with check (id = auth.uid());

-- ข้อมูลประกอบโปรไฟล์ช่าง: อ่านได้ถ้ามองเห็นช่างคนนั้น, เขียนได้เฉพาะเจ้าของ
create policy "experience read"  on public.barber_experience for select using (exists (select 1 from public.barbers b where b.id = barber_id));
create policy "experience write" on public.barber_experience for all using (barber_id = auth.uid()) with check (barber_id = auth.uid());
create policy "portfolio read"   on public.portfolio_items  for select using (exists (select 1 from public.barbers b where b.id = barber_id));
create policy "portfolio write"  on public.portfolio_items  for all using (barber_id = auth.uid()) with check (barber_id = auth.uid());
create policy "services read"    on public.services         for select using (exists (select 1 from public.barbers b where b.id = barber_id));
create policy "services write"   on public.services         for all using (barber_id = auth.uid()) with check (barber_id = auth.uid());

-- KYC: เจ้าของกับแอดมินเท่านั้น
create policy "kyc own"        on public.kyc_submissions for all using (barber_id = auth.uid()) with check (barber_id = auth.uid());
create policy "kyc admin read" on public.kyc_submissions for select using (public.is_admin());

-- orders: อ่านได้เฉพาะลูกค้า/ช่างของคิวนั้น และแอดมิน (การเขียนผ่าน RPC เท่านั้น)
create policy "orders read" on public.orders for select using (
    customer_id = auth.uid() or barber_id = auth.uid() or public.is_admin()
);
create policy "order items read" on public.order_items for select using (
    exists (select 1 from public.orders o where o.id = order_id)
);

-- reviews: ลูกค้ารีวิวได้เฉพาะคิวที่เสร็จแล้วของตัวเอง
create policy "reviews read" on public.reviews for select using (true);
create policy "reviews insert" on public.reviews for insert with check (
    customer_id = auth.uid()
    and exists (select 1 from public.orders o
                 where o.id = order_id and o.customer_id = auth.uid()
                   and o.barber_id = reviews.barber_id and o.status = 'completed')
);

-- Realtime: ให้หน้าลูกค้า/ช่างเห็นสถานะคิวเปลี่ยนทันที (ยังเคารพ RLS)
alter publication supabase_realtime add table public.orders;

-- =====================================================================
-- STORAGE (ไฟล์รูป) — โฟลเดอร์แรกของ path ต้องเป็น user id ของผู้อัปโหลด
-- =====================================================================
insert into storage.buckets (id, name, public) values
    ('avatars',       'avatars',       true),
    ('portfolio',     'portfolio',     true),
    ('travel-proofs', 'travel-proofs', false),
    ('kyc',           'kyc',           false);

create policy "upload own folder" on storage.objects for insert to authenticated with check (
    bucket_id in ('avatars', 'portfolio', 'travel-proofs', 'kyc')
    and (storage.foldername(name))[1] = auth.uid()::text
);
create policy "modify own files" on storage.objects for update to authenticated using (
    bucket_id in ('avatars', 'portfolio') and (storage.foldername(name))[1] = auth.uid()::text
);
create policy "delete own files" on storage.objects for delete to authenticated using (
    bucket_id in ('avatars', 'portfolio') and (storage.foldername(name))[1] = auth.uid()::text
);
-- รูปแคปค่าเดินทาง: ช่างเจ้าของ, ลูกค้าของคิวนั้น, แอดมิน
create policy "read travel proofs" on storage.objects for select to authenticated using (
    bucket_id = 'travel-proofs' and (
        (storage.foldername(name))[1] = auth.uid()::text
        or public.is_admin()
        or exists (select 1 from public.orders o where o.travel_proof_path = name and o.customer_id = auth.uid())
    )
);
-- เอกสาร KYC: เจ้าของและแอดมินเท่านั้น
create policy "read kyc docs" on storage.objects for select to authenticated using (
    bucket_id = 'kyc' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin())
);

-- =====================================================================
-- หลังรันเสร็จ: ตั้งบัญชีตัวเองเป็นแอดมิน (สมัครผ่านแอปก่อน แล้วแทน UUID)
-- update public.profiles set role = 'admin' where id = '<your-user-uuid>';
-- =====================================================================
