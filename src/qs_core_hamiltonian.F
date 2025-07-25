!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Calculation of the core Hamiltonian integral matrix <a|H|b> over
!>      Cartesian Gaussian-type functions.
!>
!>      <a|H|b> = <a|T|b> + <a|V|b>
!>
!>      Kinetic energy:
!>
!>      <a|T|b> = <a|-nabla**2/2|b>
!>                \_______________/
!>                        |
!>                     kinetic
!>
!>      Nuclear potential energy:
!>
!>      a) Allelectron calculation:
!>
!>                          erfc(r)
!>         <a|V|b> = -Z*<a|---------|b>
!>                             r
!>
!>                          1 - erf(r)
!>                 = -Z*<a|------------|b>
!>                              r
!>
!>                           1           erf(r)
!>                 = -Z*(<a|---|b> - <a|--------|b>)
!>                           r             r
!>
!>                           1
!>                 = -Z*(<a|---|b> - N*<ab||c>)
!>                           r
!>
!>                      -Z
!>                 = <a|---|b> + Z*N*<ab||c>
!>                       r
!>                   \_______/       \_____/
!>                       |              |
!>                    nuclear        coulomb
!>
!>      b) Pseudopotential calculation (Goedecker, Teter and Hutter; GTH):
!>
!>         <a|V|b> = <a|(V(local) + V(non-local))|b>
!>
!>                 = <a|(V(local)|b> + <a|V(non-local))|b>
!>
!>         <a|V(local)|b> = <a|-Z(eff)*erf(SQRT(2)*alpha*r)/r +
!>                             (C1 + C2*(alpha*r)**2 + C3*(alpha*r)**4 +
!>                              C4*(alpha*r)**6)*exp(-(alpha*r)**2/2))|b>
!>
!>         <a|V(non-local)|b> = <a|p(l,i)>*h(i,j)*<p(l,j)|b>
!> \par Literature
!>      S. Goedecker, M. Teter and J. Hutter, Phys. Rev. B 54, 1703 (1996)
!>      C. Hartwigsen, S. Goedecker and J. Hutter, Phys. Rev. B 58, 3641 (1998)
!>      M. Krack and M. Parrinello, Phys. Chem. Chem. Phys. 2, 2105 (2000)
!>      S. Obara and A. Saika, J. Chem. Phys. 84, 3963 (1986)
!> \par History
!>      - Joost VandeVondele (April 2003) : added LSD forces
!>      - Non-redundant calculation of the non-local part of the GTH PP
!>        (22.05.2003,MK)
!>      - New parallelization scheme (27.06.2003,MK)
!>      - OpenMP version (07.12.2003,JGH)
!>      - Binary search loop for VPPNL operators (09.01.2004,JGH,MK)
!>      - Refactoring of pseudopotential and nuclear attraction integrals (25.02.2009,JGH)
!>      - General refactoring (01.10.2010,JGH)
!>      - Refactoring related to the new kinetic energy and overlap routines (07.2014,JGH)
!>      - k-point functionality (07.2015,JGH)
!> \author Matthias Krack (14.09.2000,21.03.02)
! **************************************************************************************************
MODULE qs_core_hamiltonian
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind_set
   USE core_ae,                         ONLY: build_core_ae
   USE core_ppl,                        ONLY: build_core_ppl
   USE core_ppnl,                       ONLY: build_core_ppnl
   USE cp_blacs_env,                    ONLY: cp_blacs_env_type
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_api,                    ONLY: &
        dbcsr_add, dbcsr_copy, dbcsr_create, dbcsr_distribution_type, dbcsr_iterator_blocks_left, &
        dbcsr_iterator_next_block, dbcsr_iterator_start, dbcsr_iterator_stop, dbcsr_iterator_type, &
        dbcsr_p_type, dbcsr_set, dbcsr_type, dbcsr_type_antisymmetric
   USE cp_dbcsr_cp2k_link,              ONLY: cp_dbcsr_alloc_block_from_nbl
   USE cp_dbcsr_operations,             ONLY: dbcsr_allocate_matrix_set,&
                                              dbcsr_deallocate_matrix_set
   USE cp_dbcsr_output,                 ONLY: cp_dbcsr_write_matrix_dist,&
                                              cp_dbcsr_write_sparse_matrix
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_p_file,&
                                              cp_print_key_finished_output,&
                                              cp_print_key_should_output,&
                                              cp_print_key_unit_nr
   USE input_constants,                 ONLY: do_admm_purify_none,&
                                              do_ppl_analytic,&
                                              kg_tnadd_atomic,&
                                              rel_none,&
                                              rel_trans_atom
   USE input_section_types,             ONLY: section_vals_val_get
   USE kg_environment_types,            ONLY: kg_environment_type
   USE kg_tnadd_mat,                    ONLY: build_tnadd_mat
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE kpoint_types,                    ONLY: get_kpoint_info,&
                                              kpoint_type
   USE lri_environment_types,           ONLY: lri_environment_type
   USE message_passing,                 ONLY: mp_para_env_type
   USE particle_types,                  ONLY: particle_type
   USE qs_condnum,                      ONLY: overlap_condnum
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type,&
                                              set_qs_env
   USE qs_force_types,                  ONLY: qs_force_type
   USE qs_kind_types,                   ONLY: get_qs_kind,&
                                              qs_kind_type
   USE qs_kinetic,                      ONLY: build_kinetic_matrix
   USE qs_ks_types,                     ONLY: get_ks_env,&
                                              qs_ks_env_type,&
                                              set_ks_env
   USE qs_neighbor_list_types,          ONLY: neighbor_list_set_p_type
   USE qs_oce_methods,                  ONLY: build_oce_matrices
   USE qs_oce_types,                    ONLY: allocate_oce_set,&
                                              create_oce_set,&
                                              oce_matrix_type
   USE qs_overlap,                      ONLY: build_overlap_matrix
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE virial_types,                    ONLY: virial_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_core_hamiltonian'

   PUBLIC :: build_core_hamiltonian_matrix, core_matrices
   PUBLIC :: dump_info_core_hamiltonian, qs_matrix_h_allocate_imag_from_real

CONTAINS

! **************************************************************************************************
!> \brief Cosntruction of the QS Core Hamiltonian Matrix
!> \param qs_env ...
!> \param calculate_forces ...
!> \author Creation (11.03.2002,MK)
!>      Non-redundant calculation of the non-local part of the GTH PP (22.05.2003,MK)
!>      New parallelization scheme (27.06.2003,MK)
! **************************************************************************************************
   SUBROUTINE build_core_hamiltonian_matrix(qs_env, calculate_forces)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      LOGICAL, INTENT(IN)                                :: calculate_forces

      CHARACTER(LEN=*), PARAMETER :: routineN = 'build_core_hamiltonian_matrix'

      INTEGER                                            :: handle, ic, img, iw, nder, nders, &
                                                            nimages, nkind
      INTEGER, DIMENSION(:, :, :), POINTER               :: cell_to_index
      LOGICAL                                            :: h_is_complex, norml1, norml2, ofdft, &
                                                            use_arnoldi, use_virial
      REAL(KIND=dp)                                      :: eps_filter, eps_fit
      REAL(KIND=dp), DIMENSION(2)                        :: condnum
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_distribution_type), POINTER             :: dbcsr_dist
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_h, matrix_p, matrix_s, matrix_t, &
                                                            matrix_w
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(kg_environment_type), POINTER                 :: kg_env
      TYPE(kpoint_type), POINTER                         :: kpoints
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb, sap_oce
      TYPE(oce_matrix_type), POINTER                     :: oce
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_force_type), DIMENSION(:), POINTER         :: force
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(virial_type), POINTER                         :: virial

      IF (calculate_forces) THEN
         CALL timeset(routineN//"_forces", handle)
      ELSE
         CALL timeset(routineN, handle)
      END IF

      NULLIFY (logger)
      logger => cp_get_default_logger()

      NULLIFY (dft_control)
      CALL get_qs_env(qs_env=qs_env, dft_control=dft_control)

      ! is this a orbital-free method calculation
      ofdft = dft_control%qs_control%ofgpw

      nimages = dft_control%nimages
      IF (ofdft) THEN
         CPASSERT(nimages == 1)
      END IF

      nders = 0
      IF (calculate_forces) THEN
         nder = 1
      ELSE
         IF (cp_print_key_should_output(logger%iter_info, qs_env%input, &
                                        "DFT%PRINT%AO_MATRICES/DERIVATIVES") /= 0) THEN
            nder = 1
         ELSE
            nder = 0
         END IF
      END IF

      IF ((cp_print_key_should_output(logger%iter_info, qs_env%input, &
                                      "DFT%PRINT%AO_MATRICES/OVERLAP") /= 0 .AND. &
           BTEST(cp_print_key_should_output(logger%iter_info, qs_env%input, &
                                            "DFT%PRINT%AO_MATRICES/DERIVATIVES"), cp_p_file))) THEN
         nders = 1
      END IF

      ! the delta pulse in the periodic case needs the momentum operator,
      ! which is equivalent to the derivative of the overlap matrix
      IF (ASSOCIATED(dft_control%rtp_control)) THEN
         IF (dft_control%rtp_control%apply_delta_pulse .AND. &
             dft_control%rtp_control%periodic) THEN
            nders = 1
         END IF
      END IF

      IF (dft_control%tddfpt2_control%enabled) THEN
         nders = 1
         IF (dft_control%do_admm) THEN
            IF (dft_control%admm_control%purification_method /= do_admm_purify_none) &
               CALL cp_abort(__LOCATION__, &
                             "Only purification method NONE is possible with TDDFT at the moment")
         END IF
      END IF

      ! filter for new matrices
      eps_filter = dft_control%qs_control%eps_filter_matrix
      !
      NULLIFY (ks_env)
      CALL get_qs_env(qs_env=qs_env, ks_env=ks_env)
      NULLIFY (matrix_s, matrix_t)
      CALL get_qs_env(qs_env=qs_env, kinetic_kp=matrix_t, matrix_s_kp=matrix_s)
      NULLIFY (sab_orb)
      CALL get_qs_env(qs_env=qs_env, sab_orb=sab_orb)
      NULLIFY (rho, force, matrix_p, matrix_w)
      IF (calculate_forces) THEN
         CALL get_qs_env(qs_env=qs_env, force=force, matrix_w_kp=matrix_w)
         CALL get_qs_env(qs_env=qs_env, rho=rho)
         CALL qs_rho_get(rho, rho_ao_kp=matrix_p)
         !     *** If LSD, then combine alpha density and beta density to
         !     *** total density: alpha <- alpha + beta   and
         !     *** spin density:   beta <- alpha - beta
         !     (since all things can be computed based on the sum of these matrices anyway)
         !     (matrix_p is restored at the end of the run, matrix_w is left in its modified state
         !     (as it should not be needed afterwards)
         IF (SIZE(matrix_p, 1) == 2) THEN
            DO img = 1, nimages
               CALL dbcsr_add(matrix_p(1, img)%matrix, matrix_p(2, img)%matrix, &
                              alpha_scalar=1.0_dp, beta_scalar=1.0_dp)
               CALL dbcsr_add(matrix_p(2, img)%matrix, matrix_p(1, img)%matrix, &
                              alpha_scalar=-2.0_dp, beta_scalar=1.0_dp)
               CALL dbcsr_add(matrix_w(1, img)%matrix, matrix_w(2, img)%matrix, &
                              alpha_scalar=1.0_dp, beta_scalar=1.0_dp)
            END DO
         END IF
         ! S matrix
         CALL build_overlap_matrix(ks_env, nderivative=nders, matrixkp_s=matrix_s, &
                                   matrix_name="OVERLAP MATRIX", &
                                   basis_type_a="ORB", &
                                   basis_type_b="ORB", &
                                   sab_nl=sab_orb, calculate_forces=.TRUE., &
                                   matrixkp_p=matrix_w)
         ! T matrix
         IF (.NOT. ofdft) &
            CALL build_kinetic_matrix(ks_env, matrixkp_t=matrix_t, &
                                      matrix_name="KINETIC ENERGY MATRIX", &
                                      basis_type="ORB", &
                                      sab_nl=sab_orb, calculate_forces=.TRUE., &
                                      matrixkp_p=matrix_p, &
                                      eps_filter=eps_filter)
         ! *** If LSD, then recover alpha density and beta density     ***
         ! *** from the total density (1) and the spin density (2)     ***
         ! *** The W matrix is neglected, since it will be destroyed   ***
         ! *** in the calling force routine after leaving this routine ***
         IF (SIZE(matrix_p, 1) == 2) THEN
            DO img = 1, nimages
               CALL dbcsr_add(matrix_p(1, img)%matrix, matrix_p(2, img)%matrix, &
                              alpha_scalar=0.5_dp, beta_scalar=0.5_dp)
               CALL dbcsr_add(matrix_p(2, img)%matrix, matrix_p(1, img)%matrix, &
                              alpha_scalar=-1.0_dp, beta_scalar=1.0_dp)
            END DO
         END IF
      ELSE
         ! S matrix
         CALL build_overlap_matrix(ks_env, nderivative=nders, matrixkp_s=matrix_s, &
                                   matrix_name="OVERLAP MATRIX", &
                                   basis_type_a="ORB", &
                                   basis_type_b="ORB", &
                                   sab_nl=sab_orb)
         ! T matrix
         IF (.NOT. ofdft) &
            CALL build_kinetic_matrix(ks_env, matrixkp_t=matrix_t, &
                                      matrix_name="KINETIC ENERGY MATRIX", &
                                      basis_type="ORB", &
                                      sab_nl=sab_orb, &
                                      eps_filter=eps_filter)
      END IF

      ! (Re-)allocate H matrix based on overlap matrix
      CALL get_ks_env(ks_env, complex_ks=h_is_complex)
      CALL qs_matrix_h_allocate(qs_env, matrix_s(1, 1)%matrix, is_complex=h_is_complex)

      NULLIFY (matrix_h)
      CALL get_qs_env(qs_env, matrix_h_kp=matrix_h)

      IF (.NOT. ofdft) THEN
         DO img = 1, nimages
            CALL dbcsr_copy(matrix_h(1, img)%matrix, matrix_t(1, img)%matrix, &
                            keep_sparsity=.TRUE., name="CORE HAMILTONIAN MATRIX")
         END DO
      END IF

      NULLIFY (qs_kind_set, atomic_kind_set, particle_set)
      CALL get_qs_env(qs_env=qs_env, qs_kind_set=qs_kind_set, atomic_kind_set=atomic_kind_set, &
                      particle_set=particle_set)

      IF (.NOT. ofdft) THEN
         ! relativistic atomic correction to kinetic energy
         IF (qs_env%rel_control%rel_method /= rel_none) THEN
            IF (qs_env%rel_control%rel_transformation == rel_trans_atom) THEN
               IF (nimages == 1) THEN
                  ic = 1
               ELSE
                  CALL get_ks_env(ks_env=ks_env, kpoints=kpoints)
                  CALL get_kpoint_info(kpoint=kpoints, cell_to_index=cell_to_index)
                  ic = cell_to_index(0, 0, 0)
               END IF
               CALL build_atomic_relmat(matrix_h(1, 1)%matrix, atomic_kind_set, qs_kind_set)
            ELSE
               CPABORT("Relativistic corrections of this type are currently not implemented")
            END IF
         END IF
      END IF

      ! *** core and pseudopotentials
      CALL core_matrices(qs_env, matrix_h, matrix_p, calculate_forces, nder)

      ! *** GAPW one-center-expansion (oce) matrices
      NULLIFY (sap_oce)
      CALL get_qs_env(qs_env=qs_env, sap_oce=sap_oce)
      NULLIFY (oce)
      IF (dft_control%qs_control%gapw .OR. dft_control%qs_control%gapw_xc) THEN
         CALL get_qs_env(qs_env=qs_env, oce=oce)
         CALL create_oce_set(oce)
         nkind = SIZE(atomic_kind_set)
         CALL allocate_oce_set(oce, nkind)
         eps_fit = dft_control%qs_control%gapw_control%eps_fit
         IF (ASSOCIATED(sap_oce)) &
            CALL build_oce_matrices(oce%intac, calculate_forces, nder, qs_kind_set, particle_set, &
                                    sap_oce, eps_fit)
      END IF

      ! *** KG atomic potentials for nonadditive kinetic energy
      IF (dft_control%qs_control%do_kg) THEN
         IF (qs_env%kg_env%tnadd_method == kg_tnadd_atomic) THEN
            CALL get_qs_env(qs_env=qs_env, kg_env=kg_env, virial=virial, dbcsr_dist=dbcsr_dist)
            use_virial = virial%pv_availability .AND. (.NOT. virial%pv_numer)
            CALL build_tnadd_mat(kg_env, matrix_p, force, virial, calculate_forces, use_virial, &
                                 qs_kind_set, atomic_kind_set, particle_set, sab_orb, dbcsr_dist)
         END IF
      END IF

      ! *** Put the core Hamiltonian matrix in the QS environment ***
      CALL set_qs_env(qs_env, oce=oce)
      CALL set_ks_env(ks_env, matrix_s_kp=matrix_s, kinetic_kp=matrix_t, matrix_h_kp=matrix_h)

      ! *** Print matrices if requested
      CALL dump_info_core_hamiltonian(qs_env, calculate_forces)

      ! *** Overlap condition number
      IF (.NOT. calculate_forces) THEN
         IF (cp_print_key_should_output(logger%iter_info, qs_env%input, &
                                        "DFT%PRINT%OVERLAP_CONDITION") .NE. 0) THEN
            iw = cp_print_key_unit_nr(logger, qs_env%input, "DFT%PRINT%OVERLAP_CONDITION", &
                                      extension=".Log")
            CALL section_vals_val_get(qs_env%input, "DFT%PRINT%OVERLAP_CONDITION%1-NORM", l_val=norml1)
            CALL section_vals_val_get(qs_env%input, "DFT%PRINT%OVERLAP_CONDITION%DIAGONALIZATION", l_val=norml2)
            CALL section_vals_val_get(qs_env%input, "DFT%PRINT%OVERLAP_CONDITION%ARNOLDI", l_val=use_arnoldi)
            CALL get_qs_env(qs_env=qs_env, blacs_env=blacs_env)
            CALL overlap_condnum(matrix_s, condnum, iw, norml1, norml2, use_arnoldi, blacs_env)
         END IF
      END IF

      CALL timestop(handle)

   END SUBROUTINE build_core_hamiltonian_matrix

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
!> \param matrix_h ...
!> \param matrix_p ...
!> \param calculate_forces ...
!> \param nder ...
!> \param atcore ...
! **************************************************************************************************
   SUBROUTINE core_matrices(qs_env, matrix_h, matrix_p, calculate_forces, nder, atcore)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_h, matrix_p
      LOGICAL, INTENT(IN)                                :: calculate_forces
      INTEGER, INTENT(IN)                                :: nder
      REAL(KIND=dp), DIMENSION(:), OPTIONAL              :: atcore

      INTEGER                                            :: natom, nimages
      INTEGER, DIMENSION(:, :, :), POINTER               :: cell_to_index
      LOGICAL                                            :: all_present, my_gt_nl, ppl_present, &
                                                            ppnl_present, use_virial
      REAL(KIND=dp)                                      :: eps_ppnl
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(kpoint_type), POINTER                         :: kpoints
      TYPE(lri_environment_type), POINTER                :: lri_env
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb, sac_ae, sac_ppl, sap_ppnl
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_force_type), DIMENSION(:), POINTER         :: force
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(virial_type), POINTER                         :: virial

      NULLIFY (dft_control)
      CALL get_qs_env(qs_env=qs_env, ks_env=ks_env, dft_control=dft_control, natom=natom)
      nimages = dft_control%nimages
      IF (PRESENT(atcore)) THEN
         CPASSERT(SIZE(atcore) >= natom)
      END IF

      ! check whether a gauge transformed version of the non-local potential part has to be used
      my_gt_nl = .FALSE.
      IF (qs_env%run_rtp) THEN
         CPASSERT(ASSOCIATED(dft_control%rtp_control))
         IF (dft_control%rtp_control%velocity_gauge) THEN
            my_gt_nl = dft_control%rtp_control%nl_gauge_transform
         END IF
      END IF

      ! prepare for k-points
      NULLIFY (cell_to_index)
      IF (nimages > 1) THEN
         CALL get_ks_env(ks_env=ks_env, kpoints=kpoints)
         CALL get_kpoint_info(kpoint=kpoints, cell_to_index=cell_to_index)
         dft_control%qs_control%do_ppl_method = do_ppl_analytic
      END IF
      ! force analytic ppl calculation for GAPW methods
      IF (dft_control%qs_control%gapw .OR. dft_control%qs_control%gapw_xc) THEN
         dft_control%qs_control%do_ppl_method = do_ppl_analytic
      END IF

      ! force
      NULLIFY (force)
      IF (calculate_forces) CALL get_qs_env(qs_env=qs_env, force=force)
      ! virial
      CALL get_qs_env(qs_env=qs_env, virial=virial)
      use_virial = virial%pv_availability .AND. (.NOT. virial%pv_numer)

      NULLIFY (qs_kind_set, atomic_kind_set, particle_set)
      CALL get_qs_env(qs_env=qs_env, qs_kind_set=qs_kind_set, atomic_kind_set=atomic_kind_set, &
                      particle_set=particle_set)

      NULLIFY (sab_orb, sac_ae, sac_ppl, sap_ppnl)
      CALL get_qs_env(qs_env=qs_env, &
                      sab_orb=sab_orb, &
                      sac_ae=sac_ae, &
                      sac_ppl=sac_ppl, &
                      sap_ppnl=sap_ppnl)

      ! *** compute the nuclear attraction contribution to the core hamiltonian ***
      all_present = ASSOCIATED(sac_ae)
      IF (all_present) THEN
         CALL build_core_ae(matrix_h, matrix_p, force, virial, calculate_forces, use_virial, nder, &
                            qs_kind_set, atomic_kind_set, particle_set, sab_orb, sac_ae, &
                            nimages, cell_to_index, "ORB", atcore=atcore)
      END IF

      ! *** compute the ppl contribution to the core hamiltonian ***
      ppl_present = ASSOCIATED(sac_ppl)
      IF (ppl_present) THEN
         IF (dft_control%qs_control%do_ppl_method == do_ppl_analytic) THEN
            IF (dft_control%qs_control%lrigpw) THEN
               CALL get_qs_env(qs_env, lri_env=lri_env)
               IF (lri_env%ppl_ri) THEN
                  IF (lri_env%exact_1c_terms) THEN
                     CPABORT("not implemented")
                  END IF
               ELSE
                  CALL build_core_ppl(matrix_h, matrix_p, force, virial, calculate_forces, use_virial, nder, &
                                      qs_kind_set, atomic_kind_set, particle_set, sab_orb, sac_ppl, &
                                      nimages, cell_to_index, "ORB", atcore=atcore)
               END IF
            ELSE
               CALL build_core_ppl(matrix_h, matrix_p, force, virial, calculate_forces, use_virial, nder, &
                                   qs_kind_set, atomic_kind_set, particle_set, sab_orb, sac_ppl, &
                                   nimages, cell_to_index, "ORB", atcore=atcore)
            END IF
         END IF
      END IF

      ! *** compute the ppnl contribution to the core hamiltonian ***
      eps_ppnl = dft_control%qs_control%eps_ppnl
      ppnl_present = ASSOCIATED(sap_ppnl)
      IF (ppnl_present) THEN
         IF (.NOT. my_gt_nl) THEN
            CALL build_core_ppnl(matrix_h, matrix_p, force, virial, calculate_forces, use_virial, nder, &
                                 qs_kind_set, atomic_kind_set, particle_set, sab_orb, sap_ppnl, eps_ppnl, &
                                 nimages, cell_to_index, "ORB", atcore=atcore)
         END IF
      END IF

   END SUBROUTINE core_matrices

! **************************************************************************************************
!> \brief Adds atomic blocks of relativistic correction for the kinetic energy
!> \param matrix_h ...
!> \param atomic_kind_set ...
!> \param qs_kind_set ...
! **************************************************************************************************
   SUBROUTINE build_atomic_relmat(matrix_h, atomic_kind_set, qs_kind_set)
      TYPE(dbcsr_type), POINTER                          :: matrix_h
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set

      INTEGER                                            :: iatom, ikind, jatom
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: kind_of
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: hblock, reltmat
      TYPE(dbcsr_iterator_type)                          :: iter

      CALL get_atomic_kind_set(atomic_kind_set, kind_of=kind_of)

      CALL dbcsr_iterator_start(iter, matrix_h)
      DO WHILE (dbcsr_iterator_blocks_left(iter))
         CALL dbcsr_iterator_next_block(iter, iatom, jatom, hblock)
         IF (iatom == jatom) THEN
            ikind = kind_of(iatom)
            CALL get_qs_kind(qs_kind_set(ikind), reltmat=reltmat)
            IF (ASSOCIATED(reltmat)) hblock = hblock + reltmat
         END IF
      END DO
      CALL dbcsr_iterator_stop(iter)

   END SUBROUTINE build_atomic_relmat

! **************************************************************************************************
!> \brief Possibly prints matrices after the construction of the Core
!>     Hamiltonian Matrix
!> \param qs_env ...
!> \param calculate_forces ...
! **************************************************************************************************
   SUBROUTINE dump_info_core_hamiltonian(qs_env, calculate_forces)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      LOGICAL, INTENT(IN)                                :: calculate_forces

      CHARACTER(LEN=*), PARAMETER :: routineN = 'dump_info_core_hamiltonian'

      INTEGER                                            :: after, handle, i, ic, iw, output_unit
      LOGICAL                                            :: omit_headers
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_v
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrixkp_h, matrixkp_s, matrixkp_t
      TYPE(mp_para_env_type), POINTER                    :: para_env

      CALL timeset(routineN, handle)

      NULLIFY (logger, matrix_v, para_env)
      logger => cp_get_default_logger()
      CALL get_qs_env(qs_env, para_env=para_env)

      ! Print the distribution of the overlap matrix blocks
      ! this duplicates causes duplicate printing at the force calc
      IF (.NOT. calculate_forces) THEN
         IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                              qs_env%input, "PRINT%DISTRIBUTION"), cp_p_file)) THEN
            output_unit = cp_print_key_unit_nr(logger, qs_env%input, "PRINT%DISTRIBUTION", &
                                               extension=".distribution")
            CALL get_qs_env(qs_env, matrix_s_kp=matrixkp_s)
            CALL cp_dbcsr_write_matrix_dist(matrixkp_s(1, 1)%matrix, output_unit, para_env)
            CALL cp_print_key_finished_output(output_unit, logger, qs_env%input, "PRINT%DISTRIBUTION")
         END IF
      END IF

      CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%OMIT_HEADERS", l_val=omit_headers)
      ! Print the overlap integral matrix, if requested
      IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                           qs_env%input, "DFT%PRINT%AO_MATRICES/OVERLAP"), cp_p_file)) THEN
         iw = cp_print_key_unit_nr(logger, qs_env%input, "DFT%PRINT%AO_MATRICES/OVERLAP", &
                                   extension=".Log")
         CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%NDIGITS", i_val=after)
         after = MIN(MAX(after, 1), 16)
         CALL get_qs_env(qs_env, matrix_s_kp=matrixkp_s)
         IF (ASSOCIATED(matrixkp_s)) THEN
            DO ic = 1, SIZE(matrixkp_s, 2)
               CALL cp_dbcsr_write_sparse_matrix(matrixkp_s(1, ic)%matrix, 4, after, qs_env, para_env, &
                                                 output_unit=iw, omit_headers=omit_headers)
            END DO
            IF (BTEST(cp_print_key_should_output(logger%iter_info, qs_env%input, &
                                                 "DFT%PRINT%AO_MATRICES/DERIVATIVES"), cp_p_file)) THEN
               DO ic = 1, SIZE(matrixkp_s, 2)
                  DO i = 2, SIZE(matrixkp_s, 1)
                     CALL cp_dbcsr_write_sparse_matrix(matrixkp_s(i, ic)%matrix, 4, after, qs_env, para_env, &
                                                       output_unit=iw, omit_headers=omit_headers)
                  END DO
               END DO
            END IF
         END IF
         CALL cp_print_key_finished_output(iw, logger, qs_env%input, &
                                           "DFT%PRINT%AO_MATRICES/OVERLAP")
      END IF

      ! Print the kinetic energy integral matrix, if requested
      IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                           qs_env%input, "DFT%PRINT%AO_MATRICES/KINETIC_ENERGY"), cp_p_file)) THEN
         iw = cp_print_key_unit_nr(logger, qs_env%input, "DFT%PRINT%AO_MATRICES/KINETIC_ENERGY", &
                                   extension=".Log")
         CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%NDIGITS", i_val=after)
         after = MIN(MAX(after, 1), 16)
         CALL get_qs_env(qs_env, kinetic_kp=matrixkp_t)
         IF (ASSOCIATED(matrixkp_t)) THEN
            DO ic = 1, SIZE(matrixkp_t, 2)
               CALL cp_dbcsr_write_sparse_matrix(matrixkp_t(1, ic)%matrix, 4, after, qs_env, para_env, &
                                                 output_unit=iw, omit_headers=omit_headers)
            END DO
         END IF
         CALL cp_print_key_finished_output(iw, logger, qs_env%input, &
                                           "DFT%PRINT%AO_MATRICES/KINETIC_ENERGY")
      END IF

      ! Print the potential energy matrix, if requested
      IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                           qs_env%input, "DFT%PRINT%AO_MATRICES/POTENTIAL_ENERGY"), cp_p_file)) THEN
         iw = cp_print_key_unit_nr(logger, qs_env%input, "DFT%PRINT%AO_MATRICES/POTENTIAL_ENERGY", &
                                   extension=".Log")
         CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%NDIGITS", i_val=after)
         after = MIN(MAX(after, 1), 16)
         CALL get_qs_env(qs_env, matrix_h_kp=matrixkp_h, kinetic_kp=matrixkp_t)
         IF (ASSOCIATED(matrixkp_h)) THEN
            IF (SIZE(matrixkp_h, 2) == 1) THEN
               CALL dbcsr_allocate_matrix_set(matrix_v, 1)
               ALLOCATE (matrix_v(1)%matrix)
               CALL dbcsr_copy(matrix_v(1)%matrix, matrixkp_h(1, 1)%matrix, name="POTENTIAL ENERGY MATRIX")
               CALL dbcsr_add(matrix_v(1)%matrix, matrixkp_t(1, 1)%matrix, &
                              alpha_scalar=1.0_dp, beta_scalar=-1.0_dp)
               CALL cp_dbcsr_write_sparse_matrix(matrix_v(1)%matrix, 4, after, qs_env, &
                                                 para_env, output_unit=iw, omit_headers=omit_headers)
               CALL dbcsr_deallocate_matrix_set(matrix_v)
            ELSE
               CPWARN("Printing of potential energy matrix not implemented for k-points")
            END IF
         END IF
         CALL cp_print_key_finished_output(iw, logger, qs_env%input, &
                                           "DFT%PRINT%AO_MATRICES/POTENTIAL_ENERGY")
      END IF

      ! Print the core Hamiltonian matrix, if requested
      IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                           qs_env%input, "DFT%PRINT%AO_MATRICES/CORE_HAMILTONIAN"), cp_p_file)) THEN
         iw = cp_print_key_unit_nr(logger, qs_env%input, "DFT%PRINT%AO_MATRICES/CORE_HAMILTONIAN", &
                                   extension=".Log")
         CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%NDIGITS", i_val=after)
         after = MIN(MAX(after, 1), 16)
         CALL get_qs_env(qs_env, matrix_h_kp=matrixkp_h)
         IF (ASSOCIATED(matrixkp_h)) THEN
            DO ic = 1, SIZE(matrixkp_h, 2)
               CALL cp_dbcsr_write_sparse_matrix(matrixkp_h(1, ic)%matrix, 4, after, qs_env, para_env, &
                                                 output_unit=iw, omit_headers=omit_headers)
            END DO
         END IF
         CALL cp_print_key_finished_output(iw, logger, qs_env%input, &
                                           "DFT%PRINT%AO_MATRICES/CORE_HAMILTONIAN")
      END IF

      CALL timestop(handle)

   END SUBROUTINE dump_info_core_hamiltonian

! **************************************************************************************************
!> \brief (Re-)allocate matrix_h based on the template (typically the overlap matrix)
!> \param qs_env ...
!> \param template ...
!> \param is_complex ...
! **************************************************************************************************
   SUBROUTINE qs_matrix_h_allocate(qs_env, template, is_complex)
      TYPE(qs_environment_type)                          :: qs_env
      TYPE(dbcsr_type), INTENT(in)                       :: template
      LOGICAL, INTENT(in)                                :: is_complex

      CHARACTER(LEN=default_string_length)               :: headline
      INTEGER                                            :: img, nimages
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_h, matrix_h_im
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb
      TYPE(qs_ks_env_type), POINTER                      :: ks_env

      NULLIFY (matrix_h, matrix_h_im, sab_orb, dft_control, ks_env)
      CALL get_qs_env(qs_env=qs_env, &
                      matrix_h_kp=matrix_h, &
                      matrix_h_im_kp=matrix_h_im, &
                      sab_orb=sab_orb, &
                      dft_control=dft_control, &
                      ks_env=ks_env)

      nimages = dft_control%nimages
      CALL dbcsr_allocate_matrix_set(matrix_h, 1, nimages)
      headline = "CORE HAMILTONIAN MATRIX"
      DO img = 1, nimages
         ALLOCATE (matrix_h(1, img)%matrix)
         CALL dbcsr_create(matrix_h(1, img)%matrix, name=TRIM(headline), template=template)
         CALL cp_dbcsr_alloc_block_from_nbl(matrix_h(1, img)%matrix, sab_orb)
         CALL dbcsr_set(matrix_h(1, img)%matrix, 0.0_dp)
      END DO
      CALL set_ks_env(ks_env, matrix_h_kp=matrix_h)

      IF (is_complex) THEN
         headline = "IMAGINARY PART OF CORE HAMILTONIAN MATRIX"
         CALL dbcsr_allocate_matrix_set(matrix_h_im, 1, nimages)
         DO img = 1, nimages
            ALLOCATE (matrix_h_im(1, img)%matrix)
            CALL dbcsr_create(matrix_h_im(1, img)%matrix, name=TRIM(headline), template=template, &
                              matrix_type=dbcsr_type_antisymmetric)
            CALL cp_dbcsr_alloc_block_from_nbl(matrix_h_im(1, img)%matrix, sab_orb)
            CALL dbcsr_set(matrix_h_im(1, img)%matrix, 0.0_dp)
         END DO
         CALL set_ks_env(ks_env, matrix_h_im_kp=matrix_h_im)
      END IF

   END SUBROUTINE qs_matrix_h_allocate

! **************************************************************************************************
!> \brief (Re-)allocates matrix_h_im from matrix_h
!> \param qs_env ...
! **************************************************************************************************
   SUBROUTINE qs_matrix_h_allocate_imag_from_real(qs_env)
      TYPE(qs_environment_type)                          :: qs_env

      CHARACTER(LEN=default_string_length)               :: headline
      INTEGER                                            :: image, nimages
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_h, matrix_h_im
      TYPE(dbcsr_type), POINTER                          :: template
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb
      TYPE(qs_ks_env_type), POINTER                      :: ks_env

      NULLIFY (matrix_h_im, matrix_h, dft_control, template, sab_orb, ks_env)

      CALL get_qs_env(qs_env, &
                      matrix_h_im_kp=matrix_h_im, &
                      matrix_h_kp=matrix_h, &
                      dft_control=dft_control, &
                      sab_orb=sab_orb, &
                      ks_env=ks_env)

      nimages = dft_control%nimages

      CPASSERT(nimages .EQ. SIZE(matrix_h, 2))

      CALL dbcsr_allocate_matrix_set(matrix_h_im, 1, nimages)

      DO image = 1, nimages
         headline = "IMAGINARY CORE HAMILTONIAN MATRIX"
         ALLOCATE (matrix_h_im(1, image)%matrix)
         template => matrix_h(1, image)%matrix ! base on real part, but anti-symmetric
         CALL dbcsr_create(matrix=matrix_h_im(1, image)%matrix, template=template, &
                           name=TRIM(headline), matrix_type=dbcsr_type_antisymmetric)
         CALL cp_dbcsr_alloc_block_from_nbl(matrix_h_im(1, image)%matrix, sab_orb)
         CALL dbcsr_set(matrix_h_im(1, image)%matrix, 0.0_dp)
      END DO
      CALL set_ks_env(ks_env, matrix_h_im_kp=matrix_h_im)

   END SUBROUTINE qs_matrix_h_allocate_imag_from_real

END MODULE qs_core_hamiltonian
