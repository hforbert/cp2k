!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Calculate the derivatives of the MO coefficients wrt nuclear coordinates
!> \author Sandra Luber, Edward Ditler
! **************************************************************************************************

MODULE qs_dcdr_ao

   USE atomic_kind_types,               ONLY: atomic_kind_type
   USE basis_set_types,                 ONLY: gto_basis_set_p_type,&
                                              gto_basis_set_type
   USE core_ae,                         ONLY: build_core_ae
   USE core_ppl,                        ONLY: build_core_ppl
   USE core_ppnl,                       ONLY: build_core_ppnl
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_api,                    ONLY: dbcsr_copy,&
                                              dbcsr_get_block_p,&
                                              dbcsr_p_type,&
                                              dbcsr_set,&
                                              dbcsr_type
   USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm,&
                                              copy_fm_to_dbcsr
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_release,&
                                              cp_fm_type
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE input_constants,                 ONLY: do_ppl_analytic
   USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                              section_vals_type
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE orbital_pointers,                ONLY: ncoset
   USE parallel_gemm_api,               ONLY: parallel_gemm
   USE particle_types,                  ONLY: particle_type
   USE pw_env_types,                    ONLY: pw_env_get,&
                                              pw_env_type
   USE pw_methods,                      ONLY: pw_axpy,&
                                              pw_copy,&
                                              pw_scale,&
                                              pw_transfer,&
                                              pw_zero
   USE pw_poisson_methods,              ONLY: pw_poisson_solve
   USE pw_poisson_types,                ONLY: pw_poisson_type
   USE pw_pool_types,                   ONLY: pw_pool_p_type,&
                                              pw_pool_type
   USE pw_types,                        ONLY: pw_c1d_gs_type,&
                                              pw_r3d_rs_type
   USE qs_collocate_density,            ONLY: calculate_drho_core,&
                                              calculate_drho_elec_dR
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_force_types,                  ONLY: qs_force_type
   USE qs_integral_utils,               ONLY: basis_set_list_setup,&
                                              get_memory_usage
   USE qs_integrate_potential,          ONLY: integrate_v_dbasis,&
                                              integrate_v_rspace
   USE qs_kind_types,                   ONLY: qs_kind_type
   USE qs_ks_types,                     ONLY: get_ks_env,&
                                              qs_ks_env_type
   USE qs_linres_types,                 ONLY: dcdr_env_type
   USE qs_neighbor_list_types,          ONLY: get_iterator_info,&
                                              get_neighbor_list_set_p,&
                                              neighbor_list_iterate,&
                                              neighbor_list_iterator_create,&
                                              neighbor_list_iterator_p_type,&
                                              neighbor_list_iterator_release,&
                                              neighbor_list_set_p_type
   USE qs_rho_methods,                  ONLY: qs_rho_rebuild,&
                                              qs_rho_update_rho
   USE qs_rho_types,                    ONLY: qs_rho_create,&
                                              qs_rho_get,&
                                              qs_rho_release,&
                                              qs_rho_type
   USE qs_vxc,                          ONLY: qs_vxc_create
   USE virial_types,                    ONLY: virial_type
   USE xc,                              ONLY: xc_calc_2nd_deriv,&
                                              xc_prep_2nd_deriv
   USE xc_derivative_set_types,         ONLY: xc_derivative_set_type,&
                                              xc_dset_release
   USE xc_rho_set_types,                ONLY: xc_rho_set_release,&
                                              xc_rho_set_type

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads
!$ USE OMP_LIB, ONLY: omp_lock_kind, &
!$                    omp_init_lock, omp_set_lock, &
!$                    omp_unset_lock, omp_destroy_lock

#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE
   PUBLIC :: core_dR, d_vhxc_dR, d_core_charge_density_dR, apply_op_constant_term
   PUBLIC :: vhxc_R_perturbed_basis_functions
   PUBLIC :: hr_mult_by_delta_1d

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_dcdr_ao'

CONTAINS

! **************************************************************************************************
!> \brief Build the perturbed density matrix correction depending on the overlap derivative
!> \param qs_env ...
!> \param dcdr_env ...
!> \param overlap1 Overlap derivative in AO basis
!> \author Edward Ditler
! **************************************************************************************************
   SUBROUTINE apply_op_constant_term(qs_env, dcdr_env, overlap1)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dcdr_env_type)                                :: dcdr_env
      TYPE(dbcsr_p_type), OPTIONAL                       :: overlap1

      CHARACTER(len=*), PARAMETER :: routineN = 'apply_op_constant_term'

      INTEGER                                            :: handle, ispin
      REAL(KIND=dp)                                      :: energy_hartree
      TYPE(cp_fm_type)                                   :: rho_ao_fm, rho_ao_s1, rho_ao_s1_rho_ao, &
                                                            s1_ao
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho1_ao, rho_ao
      TYPE(pw_c1d_gs_type)                               :: rho1_tot_gspace, v_hartree_gspace
      TYPE(pw_c1d_gs_type), DIMENSION(:), POINTER        :: rho1_g, rho1_g_pw
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_poisson_type), POINTER                     :: poisson_env
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool
      TYPE(pw_r3d_rs_type)                               :: v_hartree_rspace
      TYPE(pw_r3d_rs_type), DIMENSION(:), POINTER        :: rho1_r, rho_r, tau1_r, v_rspace_new, &
                                                            v_xc, v_xc_tau
      TYPE(qs_rho_type), POINTER                         :: perturbed_density, rho
      TYPE(section_vals_type), POINTER                   :: input, xc_section
      TYPE(xc_derivative_set_type)                       :: deriv_set
      TYPE(xc_rho_set_type)                              :: rho_set

      ! Build the perturbed density matrix correction depending on the overlap derivative
      !   P1 = C0 C1 + C1 C0
      !        - C0_(mu j) S1_(jk) C0_(k nu)
      ! This routine is adapted from apply_op_2_dft. There, build_dm_response builds
      !  C0 * dCR + dCR * C0.
      ! build_dm_response is computing $-1 * (C^0 C^1 + C^1 C^0)$ and later on in the
      !  integration the factor 2 is applied to account for the occupancy.
      ! The sign is negative because the kernel is on the RHS of the Sternheimer equation.
      !
      ! The correction factor in this routine needs to have
      !      the opposite sign mathematically as (C0 C1 + C1 C0)
      !   so the same sign in the code     because of the $-1$ in dCR
      !   so the opposite sign in the code because we are on the LHS of the Sternheimer equation.
      !
      ! This term must not go into the kernel applied by the linear response solver, because
      !  for the (P)CG algorithm, all constant terms have to be on one side of the equations
      !  and all solution dependent terms must be on the other side.

      CALL timeset(routineN, handle)

      NULLIFY (auxbas_pw_pool, pw_env, rho1_r, rho1_g_pw, &
               v_xc, poisson_env, input, rho, rho1_g, v_xc_tau)

      CALL cp_fm_create(rho_ao_fm, dcdr_env%aoao_fm_struct)
      CALL cp_fm_create(rho_ao_s1, dcdr_env%aoao_fm_struct)
      CALL cp_fm_create(rho_ao_s1_rho_ao, dcdr_env%aoao_fm_struct)
      CALL cp_fm_create(s1_ao, dcdr_env%aoao_fm_struct)

      IF (PRESENT(overlap1)) THEN
         CALL copy_dbcsr_to_fm(overlap1%matrix, s1_ao)
      ELSE
         CALL copy_dbcsr_to_fm(dcdr_env%matrix_s1(dcdr_env%beta + 1)%matrix, s1_ao)
      END IF

      DO ispin = 1, dcdr_env%nspins
         CALL dbcsr_set(dcdr_env%perturbed_dm_correction(ispin)%matrix, 0._dp)
         CALL dbcsr_set(dcdr_env%matrix_apply_op_constant(ispin)%matrix, 0.0_dp)

         CALL parallel_gemm('N', 'T', dcdr_env%nao, dcdr_env%nao, dcdr_env%nmo(ispin), &
                            1.0_dp, dcdr_env%mo_coeff(ispin), dcdr_env%mo_coeff(ispin), &
                            0.0_dp, rho_ao_fm)

         CALL parallel_gemm('N', 'N', dcdr_env%nao, dcdr_env%nao, dcdr_env%nao, &
                            1.0_dp, rho_ao_fm, s1_ao, &
                            0.0_dp, rho_ao_s1)

         CALL parallel_gemm('N', 'N', dcdr_env%nao, dcdr_env%nao, dcdr_env%nao, &
                            -1._dp, rho_ao_s1, rho_ao_fm, &   ! this is the sign mentioned above.
                            0.0_dp, rho_ao_s1_rho_ao)

         CALL copy_fm_to_dbcsr(rho_ao_s1_rho_ao, dcdr_env%perturbed_dm_correction(ispin)%matrix)
      END DO

      CALL cp_fm_release(rho_ao_fm)
      CALL cp_fm_release(rho_ao_s1)
      CALL cp_fm_release(rho_ao_s1_rho_ao)
      CALL cp_fm_release(s1_ao)
      ! Done building the density matrix correction

      ! Build the density struct from the environment
      NULLIFY (perturbed_density)
      ALLOCATE (perturbed_density)
      CALL qs_rho_create(perturbed_density)
      CALL qs_rho_rebuild(perturbed_density, qs_env=qs_env)

      ! ... set the density matrix to be the perturbed density matrix
      CALL qs_rho_get(perturbed_density, rho_ao=rho1_ao)
      DO ispin = 1, dcdr_env%nspins
         CALL dbcsr_copy(rho1_ao(ispin)%matrix, dcdr_env%perturbed_dm_correction(ispin)%matrix)
      END DO

      ! ... updates rho_r and rho_g to the rho%rho_ao.
      CALL qs_rho_update_rho(rho_struct=perturbed_density, &
                             qs_env=qs_env)

      ! Also update the qs_env%rho
      CALL get_qs_env(qs_env, rho=rho)
      CALL qs_rho_update_rho(rho, qs_env=qs_env)
      CALL qs_rho_get(rho, rho_ao=rho_ao, rho_r=rho_r)

      energy_hartree = 0.0_dp

      CALL get_qs_env(qs_env=qs_env, &
                      pw_env=pw_env, &
                      input=input)

      ! Create the temporary grids
      CALL pw_env_get(pw_env, auxbas_pw_pool=auxbas_pw_pool, &
                      poisson_env=poisson_env)

      ! Allocate deriv_set and rho_set
      xc_section => section_vals_get_subs_vals(input, "DFT%XC")

      CALL xc_prep_2nd_deriv(deriv_set, rho_set, &
                             rho_r, auxbas_pw_pool, &
                             xc_section=xc_section)

      ! Done with deriv_set and rho_set

      ALLOCATE (v_rspace_new(dcdr_env%nspins))
      CALL auxbas_pw_pool%create_pw(v_hartree_gspace)
      CALL auxbas_pw_pool%create_pw(v_hartree_rspace)

      ! Calculate the Hartree potential on the total density
      CALL auxbas_pw_pool%create_pw(rho1_tot_gspace)

      CALL qs_rho_get(perturbed_density, rho_g=rho1_g, rho_r=rho1_r, tau_r=tau1_r)
      CALL pw_copy(rho1_g(1), rho1_tot_gspace)
      DO ispin = 2, dcdr_env%nspins
         CALL pw_axpy(rho1_g(ispin), rho1_tot_gspace)
      END DO

      CALL pw_poisson_solve(poisson_env, rho1_tot_gspace, &
                            energy_hartree, &
                            v_hartree_gspace)
      CALL pw_transfer(v_hartree_gspace, v_hartree_rspace)

      CALL auxbas_pw_pool%give_back_pw(rho1_tot_gspace)

      ! Calculate the second derivative of the exchange-correlation potential
      CALL xc_calc_2nd_deriv(v_xc, v_xc_tau, deriv_set, rho_set, &
                             rho1_r, rho1_g_pw, tau1_r, auxbas_pw_pool, xc_section, gapw=.FALSE.)

      DO ispin = 1, dcdr_env%nspins
         v_rspace_new(ispin) = v_xc(ispin)
      END DO
      DEALLOCATE (v_xc)

      ! Done calculating the potentials

      !-------------------------------!
      ! Add both hartree and xc terms !
      !-------------------------------!
      CALL pw_scale(v_hartree_rspace, v_hartree_rspace%pw_grid%dvol)
      DO ispin = 1, dcdr_env%nspins
         CALL pw_scale(v_rspace_new(ispin), v_rspace_new(ispin)%pw_grid%dvol)
      END DO

      DO ispin = 1, dcdr_env%nspins
         CALL dbcsr_set(dcdr_env%matrix_apply_op_constant(ispin)%matrix, 0.0_dp)
         CALL pw_axpy(v_hartree_rspace, v_rspace_new(ispin))
         IF (dcdr_env%nspins == 1) THEN
            CALL pw_scale(v_rspace_new(1), 2.0_dp)
         END IF

         CALL integrate_v_rspace(v_rspace=v_rspace_new(ispin), &
                                 hmat=dcdr_env%matrix_apply_op_constant(ispin), &
                                 qs_env=qs_env, &
                                 calculate_forces=.FALSE.)
      END DO

      CALL auxbas_pw_pool%give_back_pw(v_hartree_gspace)
      CALL auxbas_pw_pool%give_back_pw(v_hartree_rspace)
      DO ispin = 1, dcdr_env%nspins
         CALL auxbas_pw_pool%give_back_pw(v_rspace_new(ispin))
      END DO
      DEALLOCATE (v_rspace_new)

      IF (ASSOCIATED(v_xc_tau)) THEN
         CALL pw_scale(v_xc_tau(1), 2._dp*v_xc_tau(1)%pw_grid%dvol)
         CALL integrate_v_rspace(v_rspace=v_xc_tau(1), &
                                 hmat=dcdr_env%matrix_apply_op_constant(1), &
                                 qs_env=qs_env, &
                                 compute_tau=.TRUE., &
                                 calculate_forces=.FALSE.)

         CALL auxbas_pw_pool%give_back_pw(v_xc_tau(1))
         DEALLOCATE (v_xc_tau)
      END IF

      CALL qs_rho_release(perturbed_density)
      DEALLOCATE (perturbed_density)
      CALL xc_rho_set_release(rho_set, auxbas_pw_pool)
      CALL xc_dset_release(deriv_set)

      CALL timestop(handle)

   END SUBROUTINE apply_op_constant_term

! **************************************************************************************************
!> \brief Calculate the derivative of the Hartree term due to the core charge density
!> \param qs_env ...
!> \param dcdr_env ...
!> \author Edward Ditler
! **************************************************************************************************
   SUBROUTINE d_core_charge_density_dR(qs_env, dcdr_env)
      ! drho_core contribution
      ! sum over all directions
      ! output in ao x ao
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dcdr_env_type)                                :: dcdr_env

      CHARACTER(len=*), PARAMETER :: routineN = 'd_core_charge_density_dR'

      INTEGER                                            :: beta, handle
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(pw_c1d_gs_type)                               :: drho_g, v_hartree_gspace
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_poisson_type), POINTER                     :: poisson_env
      TYPE(pw_pool_p_type), DIMENSION(:), POINTER        :: pw_pools
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool
      TYPE(pw_r3d_rs_type)                               :: v_hartree_rspace
      TYPE(qs_rho_type), POINTER                         :: rho

      CALL timeset(routineN, handle)

      logger => cp_get_default_logger()

      NULLIFY (pw_env, auxbas_pw_pool, pw_pools, poisson_env, dft_control, &
               rho)

      CALL get_qs_env(qs_env=qs_env, pw_env=pw_env, rho=rho, &
                      dft_control=dft_control)

      CALL pw_env_get(pw_env, auxbas_pw_pool=auxbas_pw_pool, poisson_env=poisson_env, &
                      pw_pools=pw_pools)

      ! Create the Hartree potential grids in real and reciprocal space.
      CALL auxbas_pw_pool%create_pw(v_hartree_gspace)
      CALL auxbas_pw_pool%create_pw(v_hartree_rspace)
      ! Create the grid for the derivative of the core potential
      CALL auxbas_pw_pool%create_pw(drho_g)

      DO beta = 1, 3
         CALL pw_zero(v_hartree_gspace)
         CALL pw_zero(v_hartree_rspace)
         CALL pw_zero(drho_g)

         ! Calculate the Hartree potential on the perturbed density and Poisson solve it
         CALL calculate_drho_core(drho_core=drho_g, qs_env=qs_env, &
                                  beta=beta, lambda=dcdr_env%lambda)
         CALL pw_poisson_solve(poisson_env, drho_g, &
                               vhartree=v_hartree_gspace)
         CALL pw_transfer(v_hartree_gspace, v_hartree_rspace)
         CALL pw_scale(v_hartree_rspace, v_hartree_rspace%pw_grid%dvol)

         ! Calculate the integrals
         CALL integrate_v_rspace(v_rspace=v_hartree_rspace, &
                                 hmat=dcdr_env%matrix_core_charge_1(beta), &
                                 qs_env=qs_env, &
                                 calculate_forces=.FALSE.)
      END DO

      CALL auxbas_pw_pool%give_back_pw(drho_g)
      CALL auxbas_pw_pool%give_back_pw(v_hartree_rspace)
      CALL auxbas_pw_pool%give_back_pw(v_hartree_gspace)

      CALL timestop(handle)
   END SUBROUTINE d_core_charge_density_dR

! **************************************************************************************************
!> \brief Core Hamiltonian contributions to the operator (the pseudopotentials)
!> \param qs_env ...
!> \param dcdr_env ..
!> \author Edward Ditler
! **************************************************************************************************
   SUBROUTINE core_dR(qs_env, dcdr_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dcdr_env_type)                                :: dcdr_env

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'core_dR'

      CHARACTER(LEN=default_string_length)               :: my_basis_type
      INTEGER                                            :: handle, nder
      INTEGER, DIMENSION(:, :, :), POINTER               :: cell_to_index
      LOGICAL                                            :: calculate_forces, failure, ppl_present, &
                                                            ppnl_present, use_virial
      REAL(KIND=dp)                                      :: eps_ppnl
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: deltaR
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_ao
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_hc_pass, matrix_p_pass, &
                                                            matrix_ppnl_1_pass
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb, sac_ae, sac_ppl, sap_ppnl
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_force_type), DIMENSION(:), POINTER         :: force
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(virial_type), POINTER                         :: virial

      CALL timeset(routineN, handle)

      failure = .FALSE.

      NULLIFY (atomic_kind_set, qs_kind_set, ks_env, dft_control, particle_set, &
               sab_orb, sac_ae, sac_ppl, sap_ppnl, virial, rho, rho_ao)

      CALL get_qs_env(qs_env=qs_env, &
                      atomic_kind_set=atomic_kind_set, &
                      qs_kind_set=qs_kind_set, &
                      ks_env=ks_env, &
                      dft_control=dft_control, &
                      particle_set=particle_set, &
                      sab_orb=sab_orb, &
                      sac_ae=sac_ae, &
                      sac_ppl=sac_ppl, &
                      sap_ppnl=sap_ppnl, &
                      virial=virial)
      CALL get_ks_env(ks_env=ks_env, rho=rho)
      CALL qs_rho_get(rho, rho_ao=rho_ao)
      deltaR => dcdr_env%delta_basis_function

      nder = 1
      calculate_forces = .FALSE.

      my_basis_type = "ORB"

      ! ECP/AE contribution to the core hamiltonian
      IF (ASSOCIATED(sac_ae)) THEN
         CPABORT("ECP/AE functionality in qs_dcdr_ao missing")
         ! Missing feature: deltaR weighting factors of the derivatives wrt. nuclear positions
         matrix_hc_pass(1:3, 1:1) => dcdr_env%matrix_hc(1:3)
         matrix_p_pass(1:1, 1:1) => rho_ao(1:1)
         CALL build_core_ae(matrix_h=matrix_hc_pass, matrix_p=matrix_p_pass, &
                            force=force, virial=virial, calculate_forces=calculate_forces, &
                            use_virial=use_virial, nder=nder, qs_kind_set=qs_kind_set, &
                            atomic_kind_set=atomic_kind_set, particle_set=particle_set, &
                            sab_orb=sab_orb, sac_ae=sac_ae, nimages=1, &
                            basis_type=my_basis_type, cell_to_index=cell_to_index)
      END IF
      ! *** compute the ppl contribution to the core hamiltonian ***
      ppl_present = ASSOCIATED(sac_ppl)
      IF (ppl_present) THEN
         IF (dft_control%qs_control%do_ppl_method == do_ppl_analytic) THEN
            matrix_hc_pass(1:3, 1:1) => dcdr_env%matrix_hc(1:3)
            matrix_p_pass(1:1, 1:1) => rho_ao(1:1)
            CALL build_core_ppl(matrix_h=matrix_hc_pass, matrix_p=matrix_p_pass, &
                                force=force, virial=virial, calculate_forces=calculate_forces, &
                                use_virial=use_virial, nder=nder, qs_kind_set=qs_kind_set, &
                                atomic_kind_set=atomic_kind_set, particle_set=particle_set, &
                                sab_orb=sab_orb, sac_ppl=sac_ppl, basis_type=my_basis_type, &
                                nimages=1, cell_to_index=cell_to_index, deltaR=deltaR)

         END IF ! ppl_analytic
      END IF ! ppl_present

      ! *** compute the ppnl contribution to the core hamiltonian ***
      eps_ppnl = dft_control%qs_control%eps_ppnl
      ppnl_present = ASSOCIATED(sap_ppnl)
      IF (ppnl_present) THEN
         matrix_ppnl_1_pass(1:3, 1:1) => dcdr_env%matrix_ppnl_1(1:3)
         CALL build_core_ppnl(matrix_h=matrix_ppnl_1_pass, matrix_p=matrix_p_pass, force=force, virial=virial, &
                              calculate_forces=calculate_forces, use_virial=use_virial, nder=nder, &
                              qs_kind_set=qs_kind_set, atomic_kind_set=atomic_kind_set, &
                              particle_set=particle_set, sab_orb=sab_orb, sap_ppnl=sap_ppnl, &
                              eps_ppnl=eps_ppnl, nimages=1, cell_to_index=cell_to_index, &
                              basis_type=my_basis_type, deltaR=deltaR)
      END IF

      CALL timestop(handle)
   END SUBROUTINE core_dR

! **************************************************************************************************
!> \brief The derivatives of the basis functions going into the HXC potential wrt nuclear positions
!> \param qs_env ...
!> \param dcdr_env ...
!> \author Edward Ditler
! **************************************************************************************************
   SUBROUTINE d_vhxc_dR(qs_env, dcdr_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dcdr_env_type)                                :: dcdr_env

      CHARACTER(len=*), PARAMETER                        :: routineN = 'd_vhxc_dR'

      INTEGER                                            :: handle, idir, ispin
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_ao
      TYPE(pw_c1d_gs_type)                               :: drho_g_total, v_hartree_gspace
      TYPE(pw_c1d_gs_type), DIMENSION(:), POINTER        :: drho_g
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_poisson_type), POINTER                     :: poisson_env
      TYPE(pw_pool_p_type), DIMENSION(:), POINTER        :: pw_pools
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool
      TYPE(pw_r3d_rs_type)                               :: drho_r_total, v_hartree_rspace
      TYPE(pw_r3d_rs_type), DIMENSION(:), POINTER        :: drho_r, dtau_r, rho_r, v_xc, v_xc_tau
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(section_vals_type), POINTER                   :: input, xc_section
      TYPE(xc_derivative_set_type)                       :: my_deriv_set
      TYPE(xc_rho_set_type)                              :: my_rho_set

      CALL timeset(routineN, handle)

      CALL get_qs_env(qs_env=qs_env, &
                      pw_env=pw_env, &
                      input=input, &
                      rho=rho)
      CALL qs_rho_get(rho, rho_ao=rho_ao, rho_r=rho_r)

      xc_section => section_vals_get_subs_vals(input, "DFT%XC")

      ! get the tmp grids
      ALLOCATE (drho_r(dcdr_env%nspins))
      ALLOCATE (drho_g(dcdr_env%nspins))

      CALL pw_env_get(pw_env, auxbas_pw_pool=auxbas_pw_pool, &
                      pw_pools=pw_pools, poisson_env=poisson_env)
      CALL auxbas_pw_pool%create_pw(v_hartree_gspace)
      CALL auxbas_pw_pool%create_pw(v_hartree_rspace)

      DO ispin = 1, dcdr_env%nspins
         CALL auxbas_pw_pool%create_pw(drho_r(ispin))
         CALL auxbas_pw_pool%create_pw(drho_g(ispin))
      END DO
      CALL auxbas_pw_pool%create_pw(drho_g_total)
      CALL auxbas_pw_pool%create_pw(drho_r_total)

      DO idir = 1, 3
         CALL pw_zero(v_hartree_gspace)
         CALL pw_zero(v_hartree_rspace)
         CALL pw_zero(drho_g_total)
         CALL pw_zero(drho_r_total)

         DO ispin = 1, dcdr_env%nspins
            CALL pw_zero(drho_r(ispin))
            CALL pw_zero(drho_g(ispin))

            ! Get the density
            CALL calculate_drho_elec_dR(matrix_p=rho_ao(ispin)%matrix, &
                                        drho=drho_r(ispin), &
                                        drho_gspace=drho_g(ispin), &
                                        qs_env=qs_env, &
                                        beta=idir, lambda=dcdr_env%lambda)

            CALL pw_axpy(drho_g(ispin), drho_g_total)
            CALL pw_axpy(drho_r(ispin), drho_r_total)
         END DO
         ! Get the Hartree potential corresponding to the perturbed density
         CALL pw_poisson_solve(poisson_env, drho_g_total, &
                               vhartree=v_hartree_gspace)
         CALL pw_transfer(v_hartree_gspace, v_hartree_rspace)

         ! Get the XC potential corresponding to the perturbed density
         CALL xc_prep_2nd_deriv(my_deriv_set, my_rho_set, &
                                rho_r, auxbas_pw_pool, &
                                xc_section=xc_section)

         NULLIFY (dtau_r)
         CALL xc_calc_2nd_deriv(v_xc, v_xc_tau, my_deriv_set, my_rho_set, &
                                drho_r, drho_g, dtau_r, auxbas_pw_pool, xc_section, gapw=.FALSE.)
         IF (ASSOCIATED(v_xc_tau)) CPABORT("Meta functionals are not supported!")

         CALL xc_dset_release(my_deriv_set)
         CALL xc_rho_set_release(my_rho_set)

         !-------------------------------!
         ! Add both hartree and xc terms !
         !-------------------------------!
         DO ispin = 1, dcdr_env%nspins
            ! Can the dvol be different?
            CALL pw_scale(v_xc(ispin), v_xc(ispin)%pw_grid%dvol)
            CALL pw_axpy(v_hartree_rspace, v_xc(ispin), v_hartree_rspace%pw_grid%dvol)

            CALL integrate_v_rspace(v_rspace=v_xc(ispin), &
                                    hmat=dcdr_env%matrix_d_vhxc_dR(idir, ispin), &
                                    qs_env=qs_env, &
                                    calculate_forces=.FALSE.)

            ! v_xc gets allocated again in xc_calc_2nd_deriv
            CALL auxbas_pw_pool%give_back_pw(v_xc(ispin))
         END DO ! ispin
         DEALLOCATE (v_xc)
      END DO ! idir

      CALL auxbas_pw_pool%give_back_pw(v_hartree_gspace)
      CALL auxbas_pw_pool%give_back_pw(v_hartree_rspace)
      CALL auxbas_pw_pool%give_back_pw(drho_g_total)
      CALL auxbas_pw_pool%give_back_pw(drho_r_total)

      DO ispin = 1, dcdr_env%nspins
         CALL auxbas_pw_pool%give_back_pw(drho_g(ispin))
         CALL auxbas_pw_pool%give_back_pw(drho_r(ispin))
      END DO

      DEALLOCATE (drho_g)
      DEALLOCATE (drho_r)

      CALL timestop(handle)

   END SUBROUTINE d_vhxc_dR

! **************************************************************************************************
!> \brief The derivatives of the basis functions over which the HXC potential is integrated,
!>          so < da/dR | Vhxc | b >
!> \param qs_env ...
!> \param dcdr_env ...
!> \author Edward Ditler
! **************************************************************************************************
   SUBROUTINE vhxc_R_perturbed_basis_functions(qs_env, dcdr_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dcdr_env_type)                                :: dcdr_env

      CHARACTER(LEN=*), PARAMETER :: routineN = 'vhxc_R_perturbed_basis_functions'

      INTEGER                                            :: handle, ispin
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_vhxc_dbasis
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_p
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool
      TYPE(pw_r3d_rs_type), DIMENSION(:), POINTER        :: v_hxc_r, v_tau_rspace
      TYPE(pw_r3d_rs_type), POINTER                      :: v_hartree_r
      TYPE(qs_energy_type), POINTER                      :: energy
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(qs_rho_type), POINTER                         :: rho_struct
      TYPE(section_vals_type), POINTER                   :: input, xc_section

      CALL timeset(routineN, handle)

      NULLIFY (rho_struct, energy, input, ks_env, pw_env, matrix_p)
      CALL get_qs_env(qs_env, &
                      rho=rho_struct, &
                      energy=energy, &
                      input=input, &
                      ks_env=ks_env, &
                      pw_env=pw_env, &
                      v_hartree_rspace=v_hartree_r)
      CALL qs_rho_get(rho_struct, rho_ao_kp=matrix_p)
      xc_section => section_vals_get_subs_vals(input, "DFT%XC")

      NULLIFY (auxbas_pw_pool)
      CALL pw_env_get(pw_env, auxbas_pw_pool=auxbas_pw_pool)

      ! *** calculate the xc potential on the pw density ***
      ! *** associates v_hxc_r if the xc potential needs to be computed.
      ! If we do wavefunction fitting, we need the vxc_potential in the auxiliary basis set
      NULLIFY (v_hxc_r, v_tau_rspace)
      CALL qs_vxc_create(ks_env=ks_env, rho_struct=rho_struct, xc_section=xc_section, &
                         vxc_rho=v_hxc_r, vxc_tau=v_tau_rspace, exc=energy%exc)

      DO ispin = 1, dcdr_env%nspins
         CALL pw_scale(v_hxc_r(ispin), v_hxc_r(ispin)%pw_grid%dvol)

         ! sum up potentials and integrate
         CALL pw_axpy(v_hartree_r, v_hxc_r(ispin), 1._dp)

         matrix_vhxc_dbasis => dcdr_env%matrix_vhxc_perturbed_basis(ispin, :)
         CALL integrate_v_dbasis(v_rspace=v_hxc_r(ispin), &
                                 matrix_p=matrix_p(ispin, 1)%matrix, &
                                 matrix_vhxc_dbasis=matrix_vhxc_dbasis, &
                                 qs_env=qs_env, &
                                 lambda=dcdr_env%lambda)

         CALL auxbas_pw_pool%give_back_pw(v_hxc_r(ispin))
      END DO

      DEALLOCATE (v_hxc_r)

      CALL timestop(handle)
   END SUBROUTINE vhxc_R_perturbed_basis_functions

! **************************************************************************************************
!> \brief Enforce that one of the basis functions in < a | O | b > is centered on atom lambda.
!> \param matrix ...
!> \param qs_kind_set ...
!> \param basis_type ...
!> \param sab_nl ...
!> \param lambda Atom index
!> \param direction_Or True: < a | O | b==lambda >, False: < a==lambda | O | b >
! **************************************************************************************************
   SUBROUTINE hr_mult_by_delta_1d(matrix, qs_kind_set, basis_type, sab_nl, lambda, direction_Or)

      TYPE(dbcsr_type), POINTER                          :: matrix
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      CHARACTER(LEN=*), INTENT(IN)                       :: basis_type
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_nl
      INTEGER, INTENT(IN)                                :: lambda
      LOGICAL, INTENT(IN)                                :: direction_Or

      CHARACTER(len=*), PARAMETER :: routineN = 'hr_mult_by_delta_1d'

      INTEGER                                            :: handle, iatom, icol, ikind, irow, jatom, &
                                                            jkind, ldsab, mepos, nkind, nseta, &
                                                            nsetb, nthread
      INTEGER, DIMENSION(3)                              :: cell
      INTEGER, DIMENSION(:), POINTER                     :: la_max, la_min, lb_max, lb_min, npgfa, &
                                                            npgfb, nsgfa, nsgfb
      INTEGER, DIMENSION(:, :), POINTER                  :: first_sgfa, first_sgfb
      LOGICAL                                            :: do_symmetric, found
      REAL(KIND=dp), DIMENSION(3)                        :: rab
      REAL(KIND=dp), DIMENSION(:), POINTER               :: set_radius_a, set_radius_b
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: k_block, rpgfa, rpgfb, scon_a, scon_b, &
                                                            zeta, zetb
      TYPE(gto_basis_set_p_type), DIMENSION(:), POINTER  :: basis_set_list
      TYPE(gto_basis_set_type), POINTER                  :: basis_set_a, basis_set_b
      TYPE(neighbor_list_iterator_p_type), &
         DIMENSION(:), POINTER                           :: nl_iterator

      CALL timeset(routineN, handle)

      nkind = SIZE(qs_kind_set)

      ! check for symmetry
      CPASSERT(SIZE(sab_nl) > 0)
      CALL get_neighbor_list_set_p(neighbor_list_sets=sab_nl, symmetric=do_symmetric)

      ! prepare basis set
      ALLOCATE (basis_set_list(nkind))
      CALL basis_set_list_setup(basis_set_list, basis_type, qs_kind_set)

      ! *** Allocate work storage ***
      ldsab = get_memory_usage(qs_kind_set, basis_type)

      nthread = 1
!$    nthread = omp_get_max_threads()
      ! Iterate of neighbor list
      CALL neighbor_list_iterator_create(nl_iterator, sab_nl, nthread=nthread)

!$OMP PARALLEL DEFAULT(NONE) &
!$OMP SHARED (nthread,ldsab,nl_iterator, do_symmetric) &
!$OMP SHARED (ncoset,matrix,basis_set_list) &
!$OMP SHARED (direction_or, lambda) &
!$OMP PRIVATE (k_block,mepos,ikind,jkind,iatom,jatom,rab,cell) &
!$OMP PRIVATE (basis_set_a,basis_set_b) &
!$OMP PRIVATE (first_sgfa, la_max, la_min, npgfa, nsgfa, nseta, rpgfa, set_radius_a) &
!$OMP PRIVATE (zeta, first_sgfb, lb_max, lb_min, npgfb, nsetb, rpgfb, set_radius_b, nsgfb) &
!$OMP PRIVATE (zetb, scon_a, scon_b, irow, icol, found)

      mepos = 0
!$    mepos = omp_get_thread_num()

      DO WHILE (neighbor_list_iterate(nl_iterator, mepos=mepos) == 0)
         CALL get_iterator_info(nl_iterator, mepos=mepos, ikind=ikind, jkind=jkind, &
                                iatom=iatom, jatom=jatom, r=rab, cell=cell)
         basis_set_a => basis_set_list(ikind)%gto_basis_set
         IF (.NOT. ASSOCIATED(basis_set_a)) CYCLE
         basis_set_b => basis_set_list(jkind)%gto_basis_set
         IF (.NOT. ASSOCIATED(basis_set_b)) CYCLE
         ! basis ikind
         first_sgfa => basis_set_a%first_sgf
         la_max => basis_set_a%lmax
         la_min => basis_set_a%lmin
         npgfa => basis_set_a%npgf
         nseta = basis_set_a%nset
         nsgfa => basis_set_a%nsgf_set
         rpgfa => basis_set_a%pgf_radius
         set_radius_a => basis_set_a%set_radius
         scon_a => basis_set_a%scon
         zeta => basis_set_a%zet
         ! basis jkind
         first_sgfb => basis_set_b%first_sgf
         lb_max => basis_set_b%lmax
         lb_min => basis_set_b%lmin
         npgfb => basis_set_b%npgf
         nsetb = basis_set_b%nset
         nsgfb => basis_set_b%nsgf_set
         rpgfb => basis_set_b%pgf_radius
         set_radius_b => basis_set_b%set_radius
         scon_b => basis_set_b%scon
         zetb => basis_set_b%zet

         IF (do_symmetric) THEN
            IF (iatom <= jatom) THEN
               irow = iatom
               icol = jatom
            ELSE
               irow = jatom
               icol = iatom
            END IF
         ELSE
            irow = iatom
            icol = jatom
         END IF

         NULLIFY (k_block)
         CALL dbcsr_get_block_p(matrix, irow, icol, k_block, found)
         CPASSERT(found)

         IF (direction_Or) THEN
            IF (jatom /= lambda) k_block(:, :) = 0._dp
         ELSE IF (.NOT. direction_Or) THEN
            IF (iatom /= lambda) k_block(:, :) = 0._dp
         END IF
      END DO
!$OMP END PARALLEL
      CALL neighbor_list_iterator_release(nl_iterator)

      ! Release work storage
      DEALLOCATE (basis_set_list)

      CALL timestop(handle)

   END SUBROUTINE hr_mult_by_delta_1d

END MODULE qs_dcdr_ao
