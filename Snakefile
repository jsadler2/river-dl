import os
import pandas as pd

# add scripts dir to path

from river_dl.preproc_utils import prep_data
from river_dl.postproc_utils import predict_from_file, combined_metrics, plot_train_obs
from river_dl.train import train_model

out_dir = config['out_dir']
data_dir = config['data_dir']
x_vars = config['x_vars']
num_replicates = config['num_replicates']


rule all:
    input:
        f"{out_dir}/exp_overall_metrics.csv",


rule prep_io_data:
    input:
         os.path.join(data_dir, 'obs_temp_full'),
         os.path.join(data_dir, 'obs_flow_full'),
         os.path.join(data_dir, 'uncal_sntemp_input_output'),
         os.path.join(data_dir, 'distance_matrix_subset.npz'),
         catch_attr = os.path.join(data_dir, "seg_attr_drb.feather")
    output:
        "{outdir}/seg_{segment}/var_{variable}/prepped.npz"

    params:
        test_start_date='2004-09-30',
        n_test_yr=12,
    run:
        prep_data(input[0], input[1], input[2], input[3], x_vars,
                  catch_prop_file=input['catch_attr'],
                  exclude_file=None,
                  test_start_date=params.test_start_date,
                  primary_variable=wildcards.variable,
                  log_q=False, segs=[int(wildcards.segment)],
                  n_test_yr=params.n_test_yr, out_file=output[0])


rule train_model:
    input:
        "{outdir}/seg_{segment}/var_{variable}/prepped.npz"
    output:
        directory("{outdir}/seg_{segment}/var_{variable}/mod_{model}/lamb_{lamb}/{run_id}/trained_weights/"),
        directory("{outdir}/seg_{segment}/var_{variable}/mod_{model}/lamb_{lamb}/{run_id}/pretrained_weights/"),
    params:
        # getting the base path to put the training outputs in
        # I omit the last slash (hence '[:-1]' so the split works properly
        run_dir=lambda wildcards, output: os.path.split(output[0][:-1])[0],
        pt_epochs=50,
        ft_epochs=50,
    run:
        train_model(input[0], params.pt_epochs, params.ft_epochs, 20, params.run_dir,
                    model_type=wildcards.model, lamb=float(wildcards.lamb), seed=int(wildcards.run_id))

rule make_predictions:
    input:
        "{outdir}/seg_{segment}/var_{variable}/mod_{model}/lamb_{lamb}/{run_id}/trained_weights/",
        "{outdir}/seg_{segment}/var_{variable}/prepped.npz"
    params:
        hidden_size=20,
        half_tst=True,
    output:
        "{outdir}/seg_{segment}/var_{variable}/mod_{model}/lamb_{lamb}/{run_id}/{partition}_preds.feather",
    run:
        weight_dir = input[0] + '/'
        predict_from_file(weight_dir, input[1], params.hidden_size,
                          wildcards.partition, output[0], flow_in_temp=True,
                          half_tst=params.half_tst,
                          model=wildcards.model,
                          logged_q=False)


def get_grp_arg(wildcards):
    if wildcards.metric_type == 'overall':
        return None
    elif wildcards.metric_type == 'month':
        return 'month'
    elif wildcards.metric_type == 'reach':
        return 'seg_id_nat'
    elif wildcards.metric_type == 'month_reach':
        return ['seg_id_nat', 'month']


rule combine_metrics:
    input:
         "{outdir}/seg_{segment}/var_{variable}/mod_{model}/lamb_{lamb}/{run_id}/trn_preds.feather",
         "{outdir}/seg_{segment}/var_{variable}/mod_{model}/lamb_{lamb}/{run_id}/tst_preds.feather",
         f"{data_dir}/obs_temp_full",
         f"{data_dir}/obs_flow_full"
    output:
         "{outdir}/seg_{segment}/var_{variable}/mod_{model}/lamb_{lamb}/{run_id}/{metric_type}_metrics.csv"
    params:
        grp_arg = get_grp_arg
    run:
        combined_metrics(input[0], input[1], input[2], input[3], params.grp_arg, output[0], full_slate=False)

def get_exp_name(model, lamb):
    if model == 'lstm' and lamb==0:
        return 'single-task'
    elif model == 'lstm' and lamb==1:
        return 'multi-task'
    elif model == 'lstm' and lamb!=1:
        return f'multi-task_{lamb}'

    elif model == 'lstm_grad_correction' and lamb==1:
        return f'grad_adj'
    elif model == 'lstm_grad_correction' and lamb!=1:
        return f'grad_adj_{lamb}'


def combine_exp_metrics(csvs):
    df_list = []
    for metric_file in csvs:
        file_parts = metric_file.split('/')
        df = pd.read_csv(metric_file)

        run_id = int(file_parts[-2])
        lamb = file_parts[-3].split('lamb_')[-1]
        model = file_parts[-4].split('mod_')[-1]
        primary_var = file_parts[-5].split('var_')[-1]
        segment = int(file_parts[-6].split('seg_')[-1])

        df['run_id'] = run_id
        df['seg_id_nat'] = segment
        df['primary_var'] = primary_var
        df['model'] = model
        df['lamb'] = lamb
        df['exp'] = get_exp_name(model, float(lamb))


        df_list.append(df)
    idx_cols = ['run_id', 'seg_id_nat', 'primary_var', 'model', 'lamb', 'exp']
    df = pd.concat(df_list, axis=0)
    return df


def get_input_metric_files(wildcards):
    replicates_list = list(range(int(num_replicates)))
    metric_files = expand("{outdir}/seg_{segment}/var_{variable}/mod_{model}/lamb_{lamb}/{run_id}/{metric_type}_metrics.csv",
                        segment=config['segments'],
                        model=config['models'],
                        lamb=config['lambs'],
                        variable=config['primary_variables'],
                        run_id=replicates_list,
                        metric_type=wildcards.metric_type,
                        allow_missing=True)
    return metric_files


rule combine_overall_metrics:
    input:
        get_input_metric_files
    output:
        "{outdir}/exp_{metric_type}_metrics.csv"
    run:
        combined = combine_exp_metrics(input)
        #combined = combined.to_xarray()
        combined.to_csv(output[0], index=False)
