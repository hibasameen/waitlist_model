# Dependancies -----------

source('const/glob.R')
source('src/functions.R')

df_1 <- data.table::fread('const/df_1.csv')
df_2 <- data.table::fread('const/df_2.csv')
df_a <- data.table::fread('const/df_a.csv')
df_c <- data.table::fread('const/df_c.csv')

# Raw inputs ----------------------------------------------------------

sim_time <- (11*12)
capacity_10yr <- 1.038^(1/12)
capacity_5yr <- 1.06^(1/12)
  
# Fixed capacity by year
base_capacity <- df_1 %>%
  dplyr::group_by(t,s) %>%
  dplyr::summarise(capacity = sum(completed)) %>%
  group_by(s)%>%
  filter(t >= max(t)-12) %>%
  summarise(cap = quantile(capacity,0.5))

growth_stream <- df_1 %>%
  dplyr::filter(new != 0) %>%
  dplyr::ungroup()%>%
  dplyr::select(t,new,s) %>%
  dplyr::arrange(t) %>%
  tidyr::drop_na()

#mean of the past 12 months
starting_average <- (growth_stream %>% 
                       filter(t <= max(t)-12))$new %>% 
  mean

old_data <- df_2 %>%
  dplyr::mutate(t=t-max(t),
                z =  open)%>%
  dplyr::mutate(
      breach_flag = dplyr::case_when(
        i > 4 ~ 'breach',
        TRUE ~ 'not_breach')) %>%
  dplyr::group_by(t,breach_flag) %>%
  dplyr::summarise(z=sum(z)) %>%
  tidyr::pivot_wider(values_from=z,names_from=breach_flag) %>%
  dplyr::mutate(tot=breach+not_breach,
                ratio = breach/tot) %>%
  dplyr::ungroup()

old_data_time <- df_2 %>%
  dplyr::mutate(t=t-max(t),
                z =  open)%>%
  select(t,i,z) %>%
  drop_na() %>%
  dplyr::group_by(t) %>%
  dplyr::summarise(m = median(sum(i*z)/sum(z))*4.33)

capacity_ideal_10yr <- CreateCapacity(x=sim_time,
                            specialties=specs,
                            growth=capacity_10yr,
                            base_capacity=base_capacity)

capacity_0_5 <- CreateCapacity(x=60,
                           specialties=specs,
                           growth=capacity_5yr,
                           base_capacity=base_capacity)

midterm_capacity <- (capacity_0_5%>%filter(t==max(t)) %>% select(!t))$cap
midterm_referral <- starting_average*(referral_growth)^(60)
capacity_ratio <- midterm_referral/midterm_capacity

capacity_5_10 <- CreateReferrals(min_x=1,
                                 max_x=sim_time,
                                 specialty = specs,
                                 growth = referral_growth,
                                 starting_value = midterm_referral,
                                 jitter_factor = 0) %>%
  filter(t <= sim_time - 60) %>%
  select(!i) %>%
  mutate(t= 60 + t) %>%
  rename('cap'=open) %>%
  #decline by x val to meet drop-off rates
  mutate(cap = cap*0.9758611)

capacity_ideal_5yr <- rbind(capacity_0_5,capacity_5_10)

# Waitlist Size ----------------------------------------------------------

full_10yr_data <- CreateData(df_data = df_2,
                       ref_growth = referral_growth,
                       capacity = capacity_ideal_10yr,
                       policy = 0.5,
                       breach_limit = 4,
                       jitter_factor = 0,
                       a_lim = 0.75)$full_data %>%
  mutate(wait_time = z * i) %>%
  group_by(t) %>%
  summarise(wait_times = sum(wait_time,na.rm=T),
            z = sum(z,na.rm=T)) %>%
  mutate(mean = (wait_times/z)*4.333)


full_5yr_data <- CreateData(df_data = df_2,
                              ref_growth = referral_growth,
                              capacity = capacity_ideal_5yr,
                              policy = 0.5,
                              breach_limit = 4,
                              jitter_factor = 0,
                              a_lim = 0.75)$full_data %>%
  mutate(wait_time = z * i) %>%
  group_by(t) %>%
  summarise(wait_times = sum(wait_time,na.rm=T),
            z = sum(z,na.rm=T)) %>%
  mutate(mean = (wait_times/z)*4.333)

# Waitlist Activity & Costs -------

breach_10yr_data <- CreateData(df_data = df_2,
                    ref_growth = referral_growth,
                    capacity = capacity_ideal_10yr,
                    policy = 0.5,
                    breach_limit = 4,
                    jitter_factor = 0,
                    a_lim = 0.75)$breaches %>%
  mutate(ratio = breach/tot) %>%
  add_row(old_data %>% filter(t == 0))

breach_5yr_data <- CreateData(df_data = df_2,
                               ref_growth = referral_growth,
                               capacity = capacity_ideal_5yr,
                               policy = 0.5,
                               breach_limit = 4,
                               jitter_factor = 0,
                               a_lim = 0.75)$breaches %>%
  mutate(ratio = breach/tot) %>%
  add_row(old_data %>% filter(t == 0))

# Costs ------

activity_10yr_ideal <- CreateData(df_data = df_2,
                             ref_growth = referral_growth,
                             capacity = capacity_ideal_10yr,
                             policy = 0.5,
                             breach_limit = 4,
                             jitter_factor = 0,
                             a_lim = 0.75)$capacity %>%
  mutate(
    first = cap,
    fups = costs$fup_ratio * cap,
    ncl = (ncl_ratio) * (costs$fup_ratio + 1) * (1-proc_ratio)* cap,
    cl = (1-ncl_ratio) * (costs$fup_ratio + 1)* (1-proc_ratio)*cap,
    proc = (proc_ratio) * (costs$fup_ratio + 1)* cap,
    non_proc = (1-proc_ratio) * (costs$fup_ratio + 1)* cap,
    dc = costs$admit_ratio * costs$daycase_ratio * cap,
    ord = costs$admit_ratio * costs$ordinary_ratio * cap) %>%
  select(!cap) %>%
  mutate(date = max(lubridate::as_date(df_1$date)) + months(t))

cost_10yr_ideal <- activity_10yr_ideal %>%
  mutate(ncl_costing = ncl * ncl_cost,
         cl_costing = cl * cl_cost,
         in_cost = ord * in_cost,
         dc_cost = dc * dc_cost,
         proc_cost = proc * proc_cost) %>%
  select(date,ncl_costing,cl_costing,in_cost,dc_cost,proc_cost) %>%
  pivot_longer(cols=!date,names_to='type',values_to='cost') %>%
  mutate(date = zoo::as.yearmon(date)) %>%
  group_by(year(date),type)%>%
  summarise(cost=sum(cost,na.rm=T)/1e9,)

activity_5yr_ideal <- CreateData(df_data = df_2,
                                  ref_growth = referral_growth,
                                  capacity = capacity_ideal_5yr,
                                  policy = 0.5,
                                  breach_limit = 4,
                                  jitter_factor = 0,
                                  a_lim = 0.75)$capacity %>%
  mutate(
    first = cap,
    fups = costs$fup_ratio * cap,
    ncl = (ncl_ratio) * (costs$fup_ratio + 1) * (1-proc_ratio)* cap,
    cl = (1-ncl_ratio) * (costs$fup_ratio + 1)* (1-proc_ratio)*cap,
    proc = (proc_ratio) * (costs$fup_ratio + 1)* cap,
    non_proc = (1-proc_ratio) * (costs$fup_ratio + 1)* cap,
    dc = costs$admit_ratio * costs$daycase_ratio * cap,
    ord = costs$admit_ratio * costs$ordinary_ratio * cap) %>%
  select(!cap) %>%
  mutate(date = max(lubridate::as_date(df_1$date)) + months(t))

cost_5yr_ideal <- activity_5yr_ideal %>%
  mutate(ncl_costing = ncl * ncl_cost,
         cl_costing = cl * cl_cost,
         in_cost = ord * in_cost,
         dc_cost = dc * dc_cost,
         proc_cost = proc * proc_cost) %>%
  select(date,ncl_costing,cl_costing,in_cost,dc_cost,proc_cost) %>%
  pivot_longer(cols=!date,names_to='type',values_to='cost') %>%
  mutate(date = zoo::as.yearmon(date)) %>%
  group_by(year(date),type)%>%
  summarise(cost=sum(cost,na.rm=T)/1e9,)

growth_assumptions <- growth_assumptions %>%
  group_by(scenario) %>%
  mutate(
    prod = case_when(
      is.na(val_prod/lag(val_prod)) == T ~ 1,
      T ~val_prod/lag(val_prod)),
    pay = case_when(
      is.na(val_pay/lag(val_pay)) == T ~ 1,
      T ~ val_pay/lag(val_pay))
  ) %>%
  select(!c(val_prod,val_pay))

final_cost_data <- cost_10yr_ideal %>%
  rename(year='year(date)',
         cost_10yr = 'cost') %>%
  left_join(.,cost_5yr_ideal %>%
              rename(year='year(date)',
                     cost_5yr = 'cost'),
            by=c('year','type')) %>%
  filter(year != 2036) %>%
  group_by(type) %>%
  mutate(drug = 1.0489,
         val_drug = cumprod(drug)) %>%
  left_join(.,
            growth_assumptions %>%
              filter(scenario == '10-year') %>%
              ungroup()%>%
              select(fyear,prod,pay),
            by=c('year'='fyear')) %>%
  ungroup()%>%
  rowwise() %>%
  mutate(index = CreateIndex(w=w,
                             d = d,
                             r = r,
                             prod = prod,
                             drug = val_drug,
                             pay = pay,
                             deflator = 1),
         cost_5yr = cost_5yr * index,
         cost_10yr = cost_10yr * index) %>%
  group_by(year) %>%
  summarise(cost_10yr = sum(cost_10yr,na.rm=T),
            cost_5yr = sum(cost_5yr,na.rm=T))

data_2023 <-
  df_2 %>%
  filter(t >= max(t)-12) %>%
  summarise(cap = sum(completed,na.rm=T)) %>%
  mutate(
    first = cap,
    fups = costs$fup_ratio * cap,
    ncl = (ncl_ratio) * (costs$fup_ratio + 1) * (1-proc_ratio)* cap,
    cl = (1-ncl_ratio) * (costs$fup_ratio + 1)* (1-proc_ratio)*cap,
    proc = (proc_ratio) * (costs$fup_ratio + 1)* cap,
    non_proc = (1-proc_ratio) * (costs$fup_ratio + 1)* cap,
    dc = costs$admit_ratio * costs$daycase_ratio * cap,
    ord = costs$admit_ratio * costs$ordinary_ratio * cap) %>%
  select(!cap) %>%
  mutate(ncl_costing = ncl * ncl_cost,
         cl_costing = cl * cl_cost,
         in_cost = ord * in_cost,
         dc_cost = dc * dc_cost,
         proc_cost = proc * proc_cost)

write.csv(cost_5yr_ideal,'output/hiba_output/costs_5yr.csv')
write.csv(cost_10yr_ideal,'output/hiba_output/costs_10yr_ideal.csv')
write.csv(activity_5yr_ideal,'output/hiba_output/activity_5yr_ideal.csv')
write.csv(activity_10yr_ideal,'output/hiba_output/activity_10yr_ideal.csv')
