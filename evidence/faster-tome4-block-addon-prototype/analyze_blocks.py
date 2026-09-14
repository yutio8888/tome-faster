#!/usr/bin/env python3
"""Validate the entire declared cohort before producing any performance summary."""
import hashlib
import json
import math
from pathlib import Path
import statistics
from functools import lru_cache
import run

ROOT=Path(__file__).resolve().parent
TIME_FIELDS=('wall_ms','process_user_ms','process_system_ms','thread_user_ms','thread_system_ms','thread_cpu_ms')

def require(value,message):
    if not value:raise ValueError(message)

def same(a,b):
    return json.dumps(a,sort_keys=True,allow_nan=False)==json.dumps(b,sort_keys=True,allow_nan=False)

def read(path):
    def unique(pairs):
        out={}
        for key,value in pairs:
            require(key not in out,'duplicate JSON key')
            out[key]=value
        return out
    return json.loads(path.read_bytes(),object_pairs_hook=unique,
        parse_constant=lambda value:(_ for _ in ()).throw(ValueError('nonfinite JSON '+value)))

def numeric(value,positive=False):
    require(type(value) in (int,float) and math.isfinite(value),'finite numeric value required')
    require(value>0 if positive else value>=0,'invalid metric sign')
    return value

def final_row(result):
    rows=[r for r in result['records'] if r['kind'] in ('complete','reload')]
    require(len(rows)==1,'one completion record required')
    return rows[0]

def main_archive(result):
    rows=[a for a in result['archives'] if a['name']=='yron/game.teag']
    require(len(rows)==1,'one main archive required')
    return rows[0]

def validate():
    plan=read(ROOT/'acceptance-plan.json')
    order=plan['execution_order']
    require(len(order)==160 and len(set(order))==160,'unexpected declared cohort')
    # This check precedes opening even the first session's metrics.
    for name in order:
        for filename in ('input.json','result.json'):
            require((ROOT/'sessions'/name/filename).is_file(),'cohort is incomplete: '+name)
    require(run.sources(ROOT/'runtime')==plan['source_sha256'],'frozen runtime source changed')
    for path,expected in read(ROOT/'protected.json').items():
        require(run.digest(Path(path))==expected,'protected input changed: '+path)
    plan_sha=run.digest(ROOT/'acceptance-plan.json')
    results={};inputs={};previous_end=0;history_count=None
    for sequence,name in enumerate(order,1):
        metadata=read(ROOT/'sessions'/name/'input.json')
        result=read(ROOT/'sessions'/name/'result.json')
        case,variant,tag,mode,source=run.split_name(name)
        require(metadata['measurement_sequence']==sequence,'run order differs')
        require(metadata['acceptance_plan_sha256']==plan_sha,'plan differs')
        require(metadata['source_sha256']==plan['source_sha256'],'session source differs')
        require(metadata['addon_sha256']==plan['addon_sha256']==run.EXPECTED_ADDON,'package differs')
        require(metadata['engine_sha256']==plan['engine_sha256']==run.EXPECTED_ENGINE,'engine differs')
        require(metadata['save_sha256']==plan['source_save_sha256']==run.EXPECTED_SAVE,'source save differs')
        require(same(metadata['production_options'],plan['production_options']),'production options differ')
        require(metadata['started_unix_ns']>previous_end,'sessions overlap or order changed')
        require(result['ended_unix_ns']>metadata['started_unix_ns'],'invalid session boundary')
        previous_end=result['ended_unix_ns']
        diagnostic=metadata['diagnostic_options']
        expected=dict(case=case,variant=variant,expected_options=run.OPTIONS,
            reload=mode in ('reload','plain'),bare=False,
            block_bytes=run.CASES[case] if mode=='save' and variant=='candidate' else 0,
            read_blocks=mode=='reload',native_verify=False,load_audit=False,latency=False)
        require(same(diagnostic,expected),'diagnostic controls differ')
        require(result['exit_code']==0 and not result['timed_out'] and not result['lua_error'], 'invalid game process')
        require(result['complete'] is True and result['game_state_equal'] is True,'state/completion failed')
        setup=[r for r in result['records'] if r['kind']=='setup']
        require(len(setup)==1,'one setup record required')
        setup=setup[0]
        require(same(setup['options'],run.OPTIONS) and setup['sample_name_62']=='62','effective defaults differ')
        require(setup['fbo_gc_guard_setting'] is True and setup['fbo_guard_module_loaded'] is True,'FBO guard differs')
        require(setup['hit_warning_interval_ms']==500,'hit warning differs')
        for field,expected_source in (('inventory_source','@/engine/FasterInventory.lua'),
                                     ('fearscape_source','@/engine/FasterFearscape.lua'),
                                     ('namer_source','@/engine/FasterSaveNames.lua')):
            require(setup[field]==expected_source,'production method differs')
        require(setup['production'] is True and setup['bare'] is False,'runtime differs')
        row=final_row(result)
        require(row['runtime']=='LuaJIT 2.0.2','VM differs')
        archives={a['name']:a for a in result['archives']}
        require(len(archives)==len(result['archives']),'duplicate archives')
        history=0
        for path,a in archives.items():
            require(a['crc_valid'] is True and a['unique_names'] is True and a['main_count']==1,'invalid ZIP')
            for field in ('bytes','raw_bytes','compressed_bytes','entries'):numeric(a[field],True)
            if path not in ('yron/game.teag','world.teaw'):
                require(a['sha256']==metadata['save_files_before'][path],'historical archive changed')
                history+=1
            if path!='yron/game.teag':require(a['block'] is None,'non-main archive uses blocks')
        if history_count is None:history_count=history
        require(history==history_count,'historical archive count differs')
        main=main_archive(result)
        if mode=='save':
            require(row['kind']=='complete' and result['save_endpoint_valid'] is True,'invalid save boundary')
            require(same(row['before'],row['after']),'save changed selected live state')
            require(same(row['options'],run.OPTIONS),'save defaults differ')
            require(row['event_samples'] in ({},[]) and row['event_order'] in ({},[]),'unexpected gameplay event')
            require('latency_segments' not in row,'latency probe affected formal sample')
            require(len(row['empty_brackets'])==64,'empty bracket observations missing')
            stamps=row['save_samples']
            for prefix,end in (('save','finish'),('save_sync','sync_return')):
                for key in TIME_FIELDS:
                    start=numeric(stamps['start'][key]);finish=numeric(stamps[end][key])
                    metric=numeric(row['metrics'][prefix+'_'+key])
                    require(finish>=start,'negative observed time')
                    require(math.isclose(metric,finish-start,rel_tol=5e-7,abs_tol=0.05),'reported bracket differs')
            for key in TIME_FIELDS:
                require(row['metrics']['save_'+key]+0.05>=row['metrics']['save_sync_'+key],'sync exceeds full save')
            for boundary in ('memory_before','memory_after'):
                for value in row[boundary].values():numeric(value)
            require(row['memory_after']['process_peak_rss_kib']>=row['memory_before']['process_peak_rss_kib'],'RSS high water decreased')
            if variant=='candidate':
                block=main['block'];writes=row['block_writes']
                require(block and block['target']==run.CASES[case],'block target differs')
                require(block['native_byte_identical'] is None,'native verification contaminated timing')
                require(main['entries']==block['blocks']+2,'extra physical entries')
                require(len(writes)==1 and writes[0]['zip'].endswith('/game.teag.tmp'),'wrong writer scope')
                require(writes[0]['objects']==block['logical_objects'] and writes[0]['body_bytes']==block['logical_body_bytes'],'writer/archive counts differ')
            else:
                require(main['block'] is None and row['block_writes'] in ({},[]),'baseline contains prototype output')
        else:
            require(row['kind']=='reload' and result['save_files_unchanged'] is True,'reload modified files')
            require(metadata['source_session']==source,'reload source differs')
            source_result=results[source]
            source_main=main_archive(source_result)
            source_block=source_main['block']
            source_state=final_row(source_result)['after']
            require(same(run.canonical_loaded_state(row['state']),run.canonical_loaded_state(source_state)),'reload state differs from source')
            metrics=row['load_metrics']
            require('trace' not in metrics and 'delay_queue' not in metrics,'load audit contaminated timing')
            for key in TIME_FIELDS:
                short=numeric(metrics['call'][key]);full=numeric(metrics['with_delayed'][key])
                require(full+0.05>=short,'load boundary differs')
            if mode=='plain':
                require(row['block_reader'] is False and row['read_stats'] in ({},[]),'materialized control used block reader')
                require(main['block'] is None and main['entries']==source_block['logical_objects'],'materialized layout differs')
                require(metadata['materialized']['logical_body_sha256']==source_block['logical_body_sha256'],'materialized source programs differ')
            else:
                require(row['block_reader'] is True and len(row['read_stats'])==1,'block reader absent')
                require(main['sha256']==source_main['sha256'],'packed read source differs')
                require(row['read_stats'][0]['objects']==source_block['logical_objects'],'not all logical objects loaded')
                require(row['read_stats'][0]['cache_peak_bytes']<=4*1024*1024,'logical-byte cache bound exceeded')
        inputs[name]=metadata;results[name]=result
    for pair in plan['save_pairs']:
        baseline,candidate=(results[pair[key]] for key in ('baseline','candidate'))
        require(same(final_row(baseline)['before'],final_row(candidate)['before']),'save pair begins with different selected states')
        require(main_archive(baseline)['entries']==main_archive(candidate)['block']['logical_objects'],'save pair object counts differ')
    for pair in plan['load_pairs']:
        baseline,candidate=(results[pair[key]] for key in ('baseline','candidate'))
        require(same(final_row(baseline)['state'],final_row(candidate)['state']),'load pair selected states differ')
    return plan,inputs,results,dict(sessions=len(order),save_sessions=120,load_sessions=40,
        historical_archives_unchanged_per_session=history_count,source_hashes_fixed=True,
        all_game_state_checks_passed=True,all_archives_crc_valid=True,all_readbacks_preserved_files=True,
        plan_sha256=plan_sha)

@lru_cache(None)
def critical(probability,df):
    """Invert Student t CDF with composite Simpson integration (positive tail)."""
    normalizer=math.exp(math.lgamma((df+1)/2)-math.lgamma(df/2))/math.sqrt(df*math.pi)
    def cdf(x):
        count=4096;step=x/count
        def density(t):return normalizer*(1+t*t/df)**(-(df+1)/2)
        area=density(0)+density(x)
        area+=4*math.fsum(density(i*step) for i in range(1,count,2))
        area+=2*math.fsum(density(i*step) for i in range(2,count,2))
        return 0.5+area*step/3
    low,high=0.0,1.0
    while cdf(high)<probability:high*=2
    for _ in range(52):
        mid=(low+high)/2
        if cdf(mid)<probability:low=mid
        else:high=mid
    return (low+high)/2

def describe(values):
    return dict(n=len(values),median=statistics.median(values),mean=statistics.mean(values),
        minimum=min(values),maximum=max(values))

def paired(baseline,candidate):
    require(len(baseline)==len(candidate)>1,'paired samples required')
    for value in baseline+candidate:numeric(value)
    count=len(baseline);df=count-1
    differences=[c-b for b,c in zip(baseline,candidate)]
    delta=statistics.mean(differences)
    se=statistics.stdev(differences)/math.sqrt(count)
    two=critical(0.975,df)
    out=dict(baseline=describe(baseline),candidate=describe(candidate),
        mean_paired_delta=delta,paired_delta_ci95=[delta-two*se,delta+two*se])
    if all(value>0 for value in baseline+candidate):
        logs=[math.log(c/b) for b,c in zip(baseline,candidate)]
        mean=statistics.mean(logs);stderr=statistics.stdev(logs)/math.sqrt(count)
        upper=mean+critical(0.95,df)*stderr
        out.update(geometric_change_percent=100*math.expm1(mean),
            change_ci95_percent=[100*math.expm1(mean-two*stderr),100*math.expm1(mean+two*stderr)],
            change_upper95_percent=100*math.expm1(upper),log_mean=mean,log_upper95=upper)
    return out

def summarize(plan,inputs,results,validation):
    # Numerical inversion is checked against the independently retained df=29
    # value and the analytic df=1 (Cauchy) quantile before making gate decisions.
    require(abs(critical(0.95,29)-1.6991270265334972)<1e-9,'t quantile verification failed')
    require(abs(critical(0.95,1)-math.tan(math.pi*0.45))<1e-9,'Cauchy quantile verification failed')
    saves={};loads={};samples=[]
    for case in plan['cases']:
        pairs=[p for p in plan['save_pairs'] if p['case']==case]
        require(len(pairs)==30,'wrong save pair count')
        metrics={}
        def save_values(extract):
            return paired([extract(results[p['baseline']]) for p in pairs],
                          [extract(results[p['candidate']]) for p in pairs])
        for prefix in ('save','save_sync'):
            for key in TIME_FIELDS:
                name=prefix+'_'+key
                metrics[name]=save_values(lambda r:final_row(r)['metrics'][name])
        for key in ('bytes','raw_bytes','compressed_bytes','entries'):
            metrics['main_'+key]=save_values(lambda r:main_archive(r)[key])
        metrics['logical_body_bytes']=save_values(lambda r:
            main_archive(r)['block']['logical_body_bytes'] if main_archive(r)['block'] else main_archive(r)['raw_bytes'])
        for boundary in ('memory_before','memory_after'):
            for key in ('process_peak_rss_kib','lua_kib'):
                metrics[boundary+'_'+key]=save_values(lambda r:final_row(r)[boundary][key])
        primary=metrics['save_process_user_ms']
        saves[case]=dict(pairs=30,target_bytes=plan['cases'][case],metrics=metrics,
            save_cpu_below_one_percent=primary['log_upper95']<math.log(1.01),
            block_counts=describe([main_archive(results[p['candidate']])['block']['blocks'] for p in pairs]))
        for pair in pairs:
            sample=dict(kind='save',case=case,pair=pair['pair'])
            for variant in ('baseline','candidate'):
                result=results[pair[variant]];row=final_row(result);main=main_archive(result)
                sample[variant]=dict(session=pair[variant],metrics=row['metrics'],
                    bytes=main['bytes'],entries=main['entries'],
                    logical_objects=main['block']['logical_objects'] if main['block'] else main['entries'],
                    memory_before=row['memory_before'],memory_after=row['memory_after'])
            samples.append(sample)
        pairs=[p for p in plan['load_pairs'] if p['case']==case]
        require(len(pairs)==10,'wrong read pair count')
        metrics={}
        for prefix in ('call','with_delayed'):
            for key in TIME_FIELDS:
                metrics[prefix+'_'+key]=paired(
                    [final_row(results[p['baseline']])['load_metrics'][prefix][key] for p in pairs],
                    [final_row(results[p['candidate']])['load_metrics'][prefix][key] for p in pairs])
        loads[case]=dict(pairs=10,metrics=metrics,
            control='same candidate object programs in original per-object ZIP layout',
            block_reads=describe([final_row(results[p['candidate']])['read_stats'][0]['block_reads'] for p in pairs]))
        for pair in pairs:
            sample=dict(kind='load',case=case,pair=pair['pair'])
            for variant in ('baseline','candidate'):
                row=final_row(results[pair[variant]])
                sample[variant]=dict(session=pair[variant],metrics=row['load_metrics'])
            samples.append(sample)
    return dict(schema=1,prototype='addon-only carrier blocks',production_version='0.2.12',
        package_sha256=run.EXPECTED_ADDON,engine_sha256=run.EXPECTED_ENGINE,
        source_save_sha256=run.EXPECTED_SAVE,validation=validation,save=saves,load=loads,
        samples=samples,source_sha256=plan['source_sha256'],rules=plan['rules'],
        limitations=['One Linux/llvmpipe character fixture; no Windows or hardware GPU claim',
            'New block files require the prototype reader; stock-without-addon failure safety is not delivered',
            'Peak RSS includes process loading; Lua measurements are boundary sizes, not peaks',
            'No injected storage faults or cloud synchronization inside the formal cohort',
            'Experimental files only; production package/defaults are unchanged'])

if __name__=='__main__':
    plan,inputs,results,validation=validate()
    report=summarize(plan,inputs,results,validation)
    (ROOT/'results.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    print(json.dumps(validation))
    for case,section in report['save'].items():
        metrics=section['metrics']
        print(json.dumps(dict(case=case,save_cpu_below_one_percent=section['save_cpu_below_one_percent'],
            bytes=metrics['main_bytes'],user_cpu=metrics['save_process_user_ms'],
            full_wall=metrics['save_wall_ms'],sync_wall=metrics['save_sync_wall_ms'],
            read=report['load'][case]['metrics']['with_delayed_process_user_ms'])))
