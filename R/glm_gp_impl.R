


#' Internal Function to Fit a Gamma-Poisson GLM
#'
#' @inheritParams glm_gp
#' @inheritParams overdispersion_mle
#' @param Y any matrix-like object (e.g. `matrix()`, `DelayedArray()`, `HDF5Matrix()`) with
#'   one column per sample and row per gene.
#'
#' @return a list with four elements
#'  * `Beta` the coefficient matrix
#'  * `overdispersion` the vector with the estimated overdispersions
#'  * `Mu` a matrix with the corresponding means for each gene
#'     and sample
#'  * `size_factors` a vector with the size factor for each
#'    sample
#'  * `ridge_penalty` a vector with the ridge penalty
#'
#' @seealso [glm_gp()] and [overdispersion_mle()]
#' @keywords internal
glm_gp_impl <- function(Y, model_matrix,
                        offset = 0,
                        size_factors = c("normed_sum", "deconvolution", "poscounts", "ratio"),
                        overdispersion = TRUE,
                        overdispersion_shrinkage = TRUE,
                        ridge_penalty = 0,
                        do_cox_reid_adjustment = TRUE,
                        subsample = FALSE,
                        verbose = FALSE){
  if(is.vector(Y)){
    Y <- matrix(Y, nrow = 1)
  }
  # Error conditions
  stopifnot(is.matrix(Y) || is(Y, "DelayedArray"))
  stopifnot(is.matrix(model_matrix) && nrow(model_matrix) == ncol(Y))
  validate_Y_matrix(Y)
  subsample <- handle_subsample_parameter(Y, subsample)
  ridge_penalty <- handle_ridge_penalty_parameter(ridge_penalty, model_matrix, verbose = verbose)

  # Combine offset and size factor
  off_and_sf <- combine_size_factors_and_offset(offset, size_factors, Y, verbose = verbose)
  offset_matrix <- off_and_sf$offset_matrix
  size_factors <- off_and_sf$size_factors

  # Check if there distinct groups in model matrix
  # returns NULL if there would be more groups than columns
  # only_intercept_model <- ncol(model_matrix) == 1 && all(model_matrix == 1)
  groups <- get_groups_for_model_matrix(model_matrix)
  if(! is.null(groups) && any(ridge_penalty > 1e-10)){
    # Cannot apply ridge penalty in group-wise optimization
    groups <- NULL
  }

  # If no overdispersion, make rough first estimate
  if(isTRUE(overdispersion)){
    if(verbose){ message("Make initial dispersion estimate") }
    disp_init <- estimate_dispersions_roughly(Y, model_matrix, offset_matrix = offset_matrix)
  }else if(isFALSE(overdispersion)){
    disp_init <- rep(0, times = nrow(Y))
  }else if(is.character(overdispersion) && overdispersion == "global"){
    if(verbose){ message("Make initial dispersion estimate") }
    disp_init <- estimate_dispersions_roughly(Y, model_matrix, offset_matrix = offset_matrix)
    disp_init <- rep(median(disp_init), nrow(Y))
  }else{
    stopifnot(is.numeric(overdispersion) && (length(overdispersion) == 1 || length(overdispersion) == nrow(Y)))
    if(length(overdispersion) == 1){
      disp_init <- rep(overdispersion, times = nrow(Y))
    }else{
      disp_init <- overdispersion
    }
  }


  # Estimate the betas
  if(! is.null(groups)){
    if(verbose){ message("Make initial beta estimate") }
    beta_group_init <- estimate_betas_roughly_group_wise(Y, offset_matrix, groups)
    if(verbose){ message("Estimate beta") }
    beta_res <- estimate_betas_group_wise(Y, offset_matrix = offset_matrix,
                                         dispersions = disp_init, beta_group_init = beta_group_init,
                                         groups = groups, model_matrix = model_matrix)
  }else{
    # Init beta with reasonable values
    if(verbose){ message("Make initial beta estimate") }
    beta_init <- estimate_betas_roughly(Y, model_matrix, offset_matrix = offset_matrix, ridge_penalty = ridge_penalty)
    if(verbose){ message("Estimate beta") }
    beta_res <- estimate_betas_fisher_scoring(Y, model_matrix = model_matrix, offset_matrix = offset_matrix,
                                              dispersions = disp_init, beta_mat_init = beta_init, ridge_penalty = ridge_penalty)
  }
  Beta <- beta_res$Beta

  # Calculate corresponding predictions
  # Mu <- exp(Beta %*% t(model_matrix) + offset_matrix)
  Mu <- calculate_mu(Beta, model_matrix, offset_matrix)

  # Make estimate of over-disperion
  if(isTRUE(overdispersion) || (is.character(overdispersion) && overdispersion == "global")){
    if(verbose){ message("Estimate dispersion") }
    if(isTRUE(overdispersion)){
      disp_est <- overdispersion_mle(Y, Mu, model_matrix = model_matrix,
                                     do_cox_reid_adjustment = do_cox_reid_adjustment,
                                     subsample = subsample, verbose = verbose)$estimate
    }else if(is.character(overdispersion) && overdispersion == "global"){
      disp_est <- overdispersion_mle(Y, Mu, model_matrix = model_matrix,
                                     do_cox_reid_adjustment = do_cox_reid_adjustment,
                                     global_estimate = TRUE,
                                     subsample = subsample, verbose = verbose)$estimate
      disp_est <- rep(disp_est, times = nrow(Y))
    }

    if(isTRUE(overdispersion_shrinkage)){
      dispersion_shrinkage <- overdispersion_shrinkage(disp_est, gene_means = DelayedMatrixStats::rowMeans2(Mu),
                                                   df = subsample - ncol(model_matrix),
                                                   ql_disp_trend  = length(disp_est) >= 100,
                                                   npoints = max(0.1 * length(disp_est), 100),
                                                   verbose = verbose)
      disp_latest <- dispersion_shrinkage$dispersion_trend
    }else{
      dispersion_shrinkage <- NULL
      disp_latest <- disp_est
    }

    # Estimate the betas again (only necessary if disp_est has changed)
    if(verbose){ message("Estimate beta again") }
    if(! is.null(groups)){
      beta_res <- estimate_betas_group_wise(Y, offset_matrix = offset_matrix,
                                       dispersions = disp_latest, beta_mat_init = Beta,
                                       groups = groups, model_matrix = model_matrix)
    }else{
      beta_res <- estimate_betas_fisher_scoring(Y, model_matrix = model_matrix, offset_matrix = offset_matrix,
                                            dispersions = disp_latest, beta_mat_init = Beta, ridge_penalty = ridge_penalty)
    }
    Beta <- beta_res$Beta

    # Calculate corresponding predictions
    Mu <- calculate_mu(Beta, model_matrix, offset_matrix)
  }else if(isTRUE(overdispersion_shrinkage) || is.numeric(overdispersion_shrinkage)){
    # Given predefined disp_est shrink them
    disp_est <- disp_init
    dispersion_shrinkage <- overdispersion_shrinkage(disp_est, gene_means = DelayedMatrixStats::rowMeans2(Mu),
                                                     df = subsample - ncol(model_matrix),
                                                     disp_trend = overdispersion_shrinkage, verbose = verbose)
    disp_latest <- dispersion_shrinkage$dispersion_trend
    if(verbose){ message("Estimate beta again") }
    if(! is.null(groups)){
      beta_res <- estimate_betas_group_wise(Y, offset_matrix = offset_matrix,
                                       dispersions = disp_latest, beta_mat_init = Beta,
                                       groups = groups, model_matrix = model_matrix)
    }else{
      beta_res <- estimate_betas_fisher_scoring(Y, model_matrix = model_matrix, offset_matrix = offset_matrix,
                                            dispersions = disp_latest, beta_mat_init = Beta, ridge_penalty = ridge_penalty)
    }
    Beta <- beta_res$Beta
    # Calculate corresponding predictions
    Mu <- calculate_mu(Beta, model_matrix, offset_matrix)
  }else{
    # Use disp_init, because it is already in vector shape
    disp_est <- disp_init
    dispersion_shrinkage <- NULL
  }


  # Return everything
  list(Beta = Beta,
       overdispersions = disp_est,
       overdispersion_shrinkage_list = dispersion_shrinkage,
       deviances = beta_res$deviances,
       Mu = Mu, size_factors = size_factors,
       Offset = offset_matrix,
       ridge_penalty = ridge_penalty)
}



validate_Y_matrix <- function(Y){
  cs <- DelayedMatrixStats::colSums2(Y)
  which_is_inf <- which(is.infinite(cs))
  if(length(which_is_inf)){
    stop("The data contains infinite values ('Inf' or '-Inf') in columns: ",
         if(length(which_is_inf) > 5) paste0(paste(head(which_is_inf), collapse = ","), ", ...")
         else paste(head(which_is_inf), collapse = ","), "\n",
         "This is currently not supported by glmGamPoi.\n", call. = FALSE)
  }
  which_is_na <- which(is.na(cs))
  if(length(which_is_na)){
    stop("The data contains missing values ('NA') in columns: ",
           if(length(which_is_na) > 5) paste0(paste(head(which_is_na), collapse = ","), ", ...")
           else paste(head(which_is_na), collapse = ","), "\n",
         "This is currently not supported by glmGamPoi.\n", call. = FALSE)
  }
  which_neg_values <- which(DelayedMatrixStats::colAnys(Y < 0))
  if(length(which_neg_values)){
    stop("The data contains negative values (Y < 0) in columns: ",
         if(length(which_neg_values) > 5) paste0(paste(head(which_neg_values), collapse = ","), ", ...")
         else paste(head(which_neg_values), collapse = ","), "\n",
         "This is does not make sense as input data which has a support from (0 to 2^31-1).\n", call. = FALSE)
  }
}



get_groups_for_model_matrix <- function(model_matrix){
  if(! lte_n_equal_rows(model_matrix, ncol(model_matrix))){
    return(NULL)
  }else{
    get_row_groups(model_matrix, n_groups = ncol(model_matrix))
  }
}

