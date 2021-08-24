-- annotates commits with:
-- * parent_folder (indicating what *type* of change is being made)
-- * package 
create view package_folder_commits as 
select
  distinct parent_folder,package,author_when,id,message
from (
  select
     *,
     (CASE
        WHEN file LIKE 'sync/prod/argo/argo-sync-config/%' THEN 'argo-sync-config'
        WHEN file LIKE 'sync/prod/%' AND ( file LIKE '%.yml' or file LIKE '%.yaml' ) THEN 'prod'
        WHEN message LIKE '%Vendoring %' THEN 'automated-vendoring'
        WHEN file LIKE 'packages/vendored/manifests%' THEN 'vendored-manifests'
        WHEN file LIKE 'k8s-pkg/vendored/manifests%' THEN 'vendored-manifests'
        WHEN file LIKE 'packages/vendored/charts%' THEN 'vendored-manifests'
        WHEN file LIKE 'packages/rendering-vals/charts%' THEN 'rendering-vals-charts'
        WHEN file LIKE 'packages/kustomizations%' THEN 'kustomizations'
        WHEN file LIKE 'workloads%' THEN 'workloads'
        WHEN file LIKE '.github%' THEN 'gh_actions'
        ELSE null
      END) as parent_folder,
      (CASE
        WHEN file LIKE '%projectcontour%' THEN 'contour'
        WHEN file LIKE '%weave%' then 'weave'
        WHEN file LIKE '%metallb%' then 'metallb'
        WHEN file LIKE '%kube-prometheus%' then 'kube-prometheus'
        WHEN file LIKE '%cert-manager%' then 'cert-manager'
        WHEN file LIKE '%argo-cd%' then 'argo-cd'
        WHEN file like '%gatekeeper%' then 'gatekeeper'
        ELSE null
      END) as package 
  from commits
  left join stats
  on stats.commit_id = commits.id
) as categorized_commits
-- exclude uncategorized changes
where parent_folder is not null
-- not interested in any file changes that aren't tied to a package
and package is not null;

-- essentially a v2 of the previous view
-- since vendoring should cause a deployment, rather than vice versa, this should give us better results
-- we will get multiple cause (vendoring) commits being correlated with a single deploy commit that should subsume all those commits, but deploying the most recent update
-- previously we might get multiple deploy commits being associated with a single cause commit, which doesn't make sense
create materialized view package_commit_pair_cause_to_deploy as
select 
  -- selecting all fields and giving them friendly names
  deploy_commit.parent_folder as deploy_commit_parent_folder,
  deploy_commit.package as deploy_commit_package,
  deploy_commit.author_when as deploy_commit_author_when,
  deploy_commit.id as deploy_commit_id,
  deploy_commit.message as deploy_commit_message,
  cause_commit.parent_folder as cause_commit_parent_folder,
  cause_commit.package as cause_commit_package,
  cause_commit.author_when as cause_commit_author_when,
  cause_commit.id as cause_commit_id,
  cause_commit.message as cause_commit_message,
  -- get the time interval between cause commit and deploy commit (days/float)
  extract( epoch from (deploy_commit.author_when - cause_commit.author_when))/86400 as days_between_vendor_and_deploy
from package_folder_commits cause_commit
inner join package_folder_commits deploy_commit
on cause_commit.package = deploy_commit.package
-- note: multiple cause commits can be joined with a single deploy commit
and deploy_commit.author_when = ( 
  -- gets first deploy commit for the package after the cause commit we're interested in
  select min(author_when)
  from package_folder_commits
  where author_when>cause_commit.author_when
  and package=cause_commit.package
  and message ilike '%merge pull request%'
  -- TODO: handle cases when other changes cause a deploy, following clause needs to select all possible triggers of deploys
  and parent_folder='prod'
)
where cause_commit.parent_folder='automated-vendoring';

-- calculates deciles for the intervals between vendor and deploy. Aggregated per month over ALL packages
create materialized view packages_summary_deploy_and_cause_timing_decile as
select
  d.decile,
  avg(d.days_between_vendor_and_deploy) as "avg_days_between_vendor_and_deploy",
  date_trunc('month', deploy_commit_author_when) as deploy_month
from (
  select
    *,
    -- splits days_between_vendor_and_deploy into ten buckets, ie creates the deciles. Since we partitioned by month, we get ten buckets for each month
    ntile(10) over ( partition by date_trunc('month', deploy_commit_author_when) order by days_between_vendor_and_deploy ) as decile
  from package_commit_pair_cause_to_deploy
  where cause_commit_author_when is not null
) as d
group by deploy_month,d.decile; 

